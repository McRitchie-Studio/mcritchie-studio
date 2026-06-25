class Release
  # Pure decision logic for the multi-repo `bin/release ship` ("Run Deployment").
  #
  # Like Release::GemfileRepin this is deliberately IO-free: no git, no gem push,
  # no bundle, no network. It takes plans/listings/text in and returns
  # symbols/booleans/arrays out, so the git + gem + bundle orchestration stays in
  # bin/release and ALL the sequencing/version/ordering decisions stay here, unit
  # tested. (bin/release `require`s this file directly — it has no Rails deps.)
  #
  # The five decisions a multi-repo ship turns on:
  #   * which prod-deploy adapter handles a repo            (strategy_handler)
  #   * the hub-before-satellites app order                 (ordered_app_groups)
  #   * which of a consumer's gems still need re-pinning     (gems_to_repin)
  #   * whether a gem version must still be published        (publish_needed?)
  #   * the QA-frozen SHA to ship for a repo (or fall back)  (frozen_sha)
  module ShipSequence
    module_function

    # The ecosystem hub. Release::Ordering already sorts gems before apps, but NOT
    # the hub before the satellites — the hub (SSO/source-of-truth) ships first so
    # a satellite never goes live against a hub that hasn't caught up.
    HUB = "mcritchie-studio"

    # The prod_deploy `strategy` → the bin/release handler that runs it. Raises on
    # an unregistered strategy so a typo in config/release_repos.yml fails loudly
    # at ship time rather than silently skipping a repo's deploy.
    STRATEGY_HANDLERS = {
      "git_push_heroku" => :git_push_heroku,
      "repo_script" => :repo_script
    }.freeze

    def strategy_handler(adapter)
      STRATEGY_HANDLERS.fetch(adapter.to_s) do
        known = STRATEGY_HANDLERS.keys.join(", ")
        raise ArgumentError, "unknown prod_deploy strategy: #{adapter.inspect} (known: #{known})"
      end
    end

    # The app deploy groups with the hub pulled to the front, the rest left in
    # their incoming (producer-first) order. Stable: a non-hub group keeps its
    # relative position. Accepts symbol- OR string-keyed groups (repo_plan returns
    # symbols on the record side; the CLI sees string keys after JSON).
    def ordered_app_groups(app_groups)
      hub, rest = Array(app_groups).partition { |group| group_repo(group) == HUB }
      hub + rest
    end

    # The subset of `published_gem_names` whose line in `gemfile_text` still points
    # at a branch/source (so prod must be re-pinned to the published version before
    # it deploys). Composes GemfileRepin so the "what's a source ref" rule lives in
    # exactly one place. Already-pinned gems drop out → an idempotent re-pin pass.
    def gems_to_repin(published_gem_names, gemfile_text)
      Array(published_gem_names).select do |gem_name|
        Release::GemfileRepin.references_branch?(gemfile_text, gem_name)
      end
    end

    # Should we publish `version`? No when it is already LIVE on RubyGems (an
    # idempotent skip — the gem made it in a prior run). `remote_versions` is the
    # RubyGems versions listing from /api/v1/versions/<gem>.json: an array of
    # { "number" => ... } entries, all LIVE — RubyGems excludes yanked versions
    # from the listing entirely (there is no `yanked` field). It also accepts a
    # plain array of version strings (the `gem list` shape). A yanked number is
    # simply absent → publish_needed? is true → ship attempts the push → RubyGems
    # rejects re-pushing it → publish_gem aborts. That is the yank safety, and it
    # fails closed at `gem push`, so there is no listing-based yanked? check.
    def publish_needed?(version, remote_versions)
      !live_numbers(remote_versions).include?(version.to_s)
    end

    # The QA-frozen SHA to ship for `repo` — the value `bin/release prepare`
    # recorded under release.metadata["qa_shas"] (apps AND gems both freeze their
    # origin/release HEAD there). Returns the frozen SHA string when present, or
    # nil to SIGNAL the caller to fall back to resolving origin/release HEAD live
    # — for a repo absent from qa_shas, or one prepared before SHA recording. Pure:
    # the live git fallback stays in bin/release's frozen_sha_for, which delegates
    # this decision here so the shell keeps no branching of its own. A blank
    # recorded value reads as absent (fall back). Accepts string- or symbol-keyed
    # qa_shas (the CLI passes JSON string keys; the record side may use symbols).
    def frozen_sha(qa_shas, repo)
      shas = qa_shas || {}
      sha = (shas[repo] || shas[repo.to_s] || shas[repo.to_sym]).to_s
      sha.empty? ? nil : sha
    end

    # --- ship preflight: every app checkout on a clean `main` before any ff ----
    #
    # `bin/release ship` fast-forwards each app repo's `main` up to the QA-frozen
    # SHA, then runs the suite on that tree (avi_ship_gate) — both assume the
    # checkout is ON `main` with a CLEAN tree. A review agent that left a checkout
    # on a `pr-NNN` branch, or a stale uncommitted `schema.rb`, breaks the ff
    # mid-ship (after gems publish / the operator gate — the worst time). This is
    # the PURE decision half of the preflight: the I/O (git rev-parse / status)
    # lives in bin/release's ship_preflight, which hands the gathered states here.
    #
    # `states` is an array of string-keyed hashes, one per app repo:
    #   { "repo" => ..., "branch" => <current branch>,
    #     "dirty" => <bool>, "dirty_files" => [paths] }
    # `dirty` is optional — if absent it's inferred from a non-empty dirty_files.
    # Returns the OFFENDERS (repos not on `main` OR with a dirty tree), each as:
    #   { "repo" =>, "branch" =>, "on_main" => <bool>, "dirty" => <bool>,
    #     "dirty_files" => [paths] }
    # An empty result means every checkout is on a clean `main` — safe to ff.
    def preflight_offenders(states)
      Array(states).filter_map do |s|
        branch    = (s["branch"] || s[:branch]).to_s
        all_files = Array(s["dirty_files"] || s[:dirty_files]).map(&:to_s).reject(&:empty?)
        # Drop KNOWN-GENERATED artifacts (a `bin/release retro` doc, the
        # agent-worktree ledger) — they routinely sit uncommitted in the deploy
        # checkout and counting them as dirt blocked EVERY ship's fast-forward.
        # Narrow allowlist (see GENERATED_ARTIFACT_GLOBS), NOT a blanket docs/
        # ignore — any other dirty file still gates the ship.
        files = all_files.reject { |f| generated_artifact?(f) }
        dirty = if all_files.any?
                  # A concrete file list is authoritative: dirty IFF a non-
                  # generated file remains after the allowlist.
                  files.any?
                elsif s.key?("dirty") || s.key?(:dirty)
                  # No file list given — honor an explicit dirty flag (legacy shape).
                  !!(s["dirty"] || s[:dirty])
                else
                  false
                end
        on_main = branch == "main"
        next if on_main && !dirty

        { "repo" => (s["repo"] || s[:repo]).to_s, "branch" => branch,
          "on_main" => on_main, "dirty" => dirty, "dirty_files" => files }
      end
    end

    # Generated artifacts that routinely sit UNCOMMITTED in a deploy checkout but
    # are NOT real code dirt, so the ship preflight must not count them as dirty
    # (they blocked EVERY ship's fast-forward otherwise):
    #   * docs/agents/audits/retro-rel-*.md     — written by `bin/release retro`
    #   * docs/agents/maintenance/delete-later.md — the `bin/agent-worktree` ledger
    # A NARROW allowlist of globs, NOT a blanket docs/ ignore: any other dirty
    # file — including other docs — still gates the ship.
    GENERATED_ARTIFACT_GLOBS = [
      "docs/agents/audits/retro-rel-*.md",
      "docs/agents/maintenance/delete-later.md"
    ].freeze

    # Whether a repo-root-relative `path` (as `git status --porcelain` emits it)
    # is a known generated artifact. Pure string match (File.fnmatch touches no
    # filesystem); FNM_PATHNAME keeps `*` from spanning `/`, so the glob can't
    # over-ignore a nested path. A blank path is never an artifact.
    def generated_artifact?(path)
      p = path.to_s.strip
      return false if p.empty?

      GENERATED_ARTIFACT_GLOBS.any? { |glob| File.fnmatch?(glob, p, File::FNM_PATHNAME) }
    end

    # The loud, actionable abort text for a non-empty preflight_offenders list —
    # names each offending repo with WHY (off-main branch and/or the first dirty
    # files) and the one-line fix. Pure string building so it's unit-tested
    # alongside the decision.
    def preflight_message(offenders)
      lines = Array(offenders).map do |o|
        reasons = []
        reasons << "on '#{o['branch']}', not 'main'" unless o["on_main"]
        if o["dirty"]
          files = Array(o["dirty_files"])
          sample = files.first(5).join(", ")
          more = files.size > 5 ? " (+#{files.size - 5} more)" : ""
          reasons << "dirty tree#{sample.empty? ? '' : ": #{sample}#{more}"}"
        end
        "  - #{o['repo']}: #{reasons.join('; ')}"
      end
      "ship preflight failed — app checkout(s) not on a clean `main` before the fast-forward:\n" \
        "#{lines.join("\n")}\n" \
        "  Fix each (git -C <repo> checkout main && git pull; commit/stash/discard local changes), " \
        "then re-run `bin/release ship`."
    end

    # --- internals -----------------------------------------------------------

    def group_repo(group)
      (group[:repo] || group["repo"]).to_s
    end

    # The version numbers in a RubyGems listing. The listing is already live-only
    # (yanked versions don't appear), so this is a straight map to number strings.
    def live_numbers(remote_versions)
      Array(remote_versions).map { |entry| version_number(entry) }
    end

    # The version string out of either a {"number" => "x"} hash (the versions API
    # shape) or a bare "x" (the `gem list` shape).
    def version_number(entry)
      (entry.is_a?(Hash) ? (entry["number"] || entry[:number]) : entry).to_s
    end
  end
end
