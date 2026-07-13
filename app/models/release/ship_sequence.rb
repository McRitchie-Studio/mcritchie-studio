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

    # --- G4 self-gating: skip a ship test gate G3 already certified ------------
    #
    # The 90/10 policy runs the full suite ONCE per release batch: the hub
    # registers its FULL suite as `qa_test_cmd`, so the G3 pre-QA gate certifies
    # the batch on origin/release BEFORE anything deploys. Re-running the ship
    # test gate then proves nothing new — so G4 may skip it. But it may ONLY skip
    # on PROOF that G3 actually ran and passed.
    #
    # SAFETY BUG this closes (found 2026-07-12): the old predicate inferred that
    # proof from the REGISTRY plus `qa_shas` — `test_cmd == qa_test_cmd &&
    # frozen_sha == qa_sha`. Neither term proves a suite ever RAN:
    #   * `qa_shas` is stamped by the QA DEPLOY LOOP (bin/release.rb), not by the
    #     gate. It records what was DEPLOYED, never what was CERTIFIED.
    #   * the registry is read fresh at ship, so it can differ from what prepare
    #     read minutes earlier.
    # Together they let G3 skip and G4 STILL self-skip — silently disarming the
    # production gate. The documented gate-skip recipe walked exactly into this:
    # comment out `qa_test_cmd` so prepare's gate skips, then RESTORE the file
    # before ship (ship's preflight REFUSED a dirty primary back then) — and now
    # the registry reads equal again, the deployed SHA matches, and G4 skips a
    # suite NOTHING ever ran. A skipped G3 must never certify a SHA.
    #
    # THE FIX: skip only against the gate's OWN recorded verdict —
    # release.metadata["qa_gates"][repo] = {"sha", "cmd", "ok"}, written by
    # pre_qa_gate ONLY after the suite comes back green (Conductor.record_qa_gate).
    # Skip iff that record exists, is green, and matches BOTH the command the ship
    # gate would run AND the frozen ship SHA. Anything else — no record, a red
    # record, a different command, a drifted/straggler SHA — FAILS OPEN and runs
    # the gate. The caller (bin/release test_gate) records the skip as a visible
    # gate SOP, never a silent omission.
    #
    # AND: a G3 whose AUDITOR went red (`record["ci"]["state"] == "red"` — GitHub
    # CI called that same SHA broken while the local gate called it green) also
    # FAILS OPEN. This is what makes G4 a real backstop for the cross-check's
    # dangerous direction instead of a claimed one: on a green G3 the frozen ship
    # SHA is the certified SHA, so WITHOUT this clause the skip fires and the G3
    # alarm is the ONLY thing between a CI-red commit and production. A gate
    # system that claims a backstop it does not have makes its own alarm
    # dismissible.
    #
    # FAIL-OPEN ONLY, NEVER FAIL-CLOSED. The auditor may cause MORE checking; it
    # may never block a ship on its own. Only the literal state "red" arms this —
    # "none"/"pending"/"unverified" (GitHub had nothing to say: today ci.yml
    # doesn't even build `release`) and an absent "ci" key are SILENCE, and
    # silence changes nothing. The cost of a false red is one redundant suite run.
    def ship_gate_skip?(test_cmd:, frozen_sha:, qa_gate:)
      cmd = test_cmd.to_s.strip
      sha = frozen_sha.to_s.strip
      return false if cmd.empty? || sha.empty?

      record = qa_gate.is_a?(Hash) ? qa_gate : {}
      return false unless record["ok"] == true || record[:ok] == true
      return false if auditor_red?(record)

      certified_cmd = (record["cmd"] || record[:cmd]).to_s.strip
      certified_sha = (record["sha"] || record[:sha]).to_s.strip
      certified_cmd == cmd && certified_sha == sha
    end

    # Did GitHub CI call the SHA G3 certified BROKEN? Only a literal "red" counts
    # (see ship_gate_skip?): every other state — and no auditor at all — is no
    # data, and no data must never arm or block the ship gate.
    def auditor_red?(qa_gate)
      record = qa_gate.is_a?(Hash) ? qa_gate : {}
      ci = record["ci"] || record[:ci]
      return false unless ci.is_a?(Hash)

      (ci["state"] || ci[:state]).to_s == "red"
    end

    # The G3 gate record for a repo out of release.metadata["qa_gates"] (the twin
    # of frozen_sha for qa_shas). nil when the gate never recorded a verdict for
    # this repo — which ship_gate_skip? reads as "not certified" and runs the gate.
    def qa_gate(qa_gates, repo)
      gates = qa_gates.is_a?(Hash) ? qa_gates : {}
      record = gates[repo] || gates[repo.to_s] || gates[repo.to_sym]
      record.is_a?(Hash) ? record : nil
    end

    # --- ship preflight -------------------------------------------------------
    #
    # HISTORY — why this is no longer a GATE for apps (2026-07-12). ship used to
    # fast-forward each app repo's `main` in the SHARED PRIMARY and run the
    # satellites' bin/deploy there, so it REFUSED a primary that was dirty or off
    # `main`. That refusal aborted a real production ship AFTER the gems had
    # published, because a concurrent feature session had staged work in the
    # primary — work nobody may discard. The deploy now runs from its own
    # workspace (Release::GateWorkspace, role "ship") and advances `main` with a
    # ref push that reads no working tree at all, so an app primary's state is
    # simply NOT INPUT to the ship any more. What was an abort is now an ADVISORY
    # (advisory_message): the ship says it isn't reading the tree, prints the
    # rescue, and deploys.
    #
    # This detector is the PURE half of that advisory: the I/O (git rev-parse /
    # status) lives in bin/release's ship_preflight, which hands the gathered
    # states here.
    #
    # `states` is an array of string-keyed hashes, one per repo:
    #   { "repo" => ..., "branch" => <current branch>,
    #     "dirty" => <bool>, "dirty_files" => [paths], "tracked_dirty" => [paths] }
    # `dirty` is optional — if absent it's inferred from a non-empty dirty_files.
    # Returns the OFFENDERS (repos not on `main` OR with a dirty tree), each as:
    #   { "repo" =>, "branch" =>, "on_main" => <bool>, "dirty" => <bool>,
    #     "dirty_files" => [paths] }
    # An empty result means every checkout is on a clean `main`.
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
    # file — including other docs — still gates a gem build.
    GENERATED_ARTIFACT_GLOBS = [
      "docs/agents/audits/retro-rel-*.md",
      "docs/agents/maintenance/delete-later.md"
    ].freeze

    # The worktree parent — the gate + ship workspaces, and the agent worktrees,
    # all live under it. Every app repo gitignores it, but that is a CONVENTION
    # (a newly-onboarded repo can miss the .gitignore line), and if it is ever
    # missed the ship's own `.worktrees/_ship` would show up in `git status` as
    # the operator's "stranded work" — the advisory would name it, and the rescue
    # command would COMMIT THE WORKSPACE INTO GIT. It is tooling output by
    # definition, never anyone's work, so it can never count as dirt.
    WORKSPACE_DIR = ".worktrees".freeze

    # Whether a repo-root-relative `path` (as `git status --porcelain` emits it)
    # is a known generated artifact. Pure string match (File.fnmatch touches no
    # filesystem); FNM_PATHNAME keeps `*` from spanning `/`, so the glob can't
    # over-ignore a nested path. A blank path is never an artifact. `git status`
    # reports an untracked DIRECTORY with a trailing slash (`.worktrees/`), so the
    # path is normalized before matching.
    def generated_artifact?(path)
      p = path.to_s.strip.chomp("/")
      return false if p.empty?
      return true if p == WORKSPACE_DIR || p.start_with?("#{WORKSPACE_DIR}/")

      GENERATED_ARTIFACT_GLOBS.any? { |glob| File.fnmatch?(glob, p, File::FNM_PATHNAME) }
    end

    # The app-primary ADVISORY (never an abort). The ship does not read these
    # trees — it deploys from its own workspace at the frozen SHA — so a dirty or
    # off-main primary is now just a note, plus the rescue for the operator who
    # WANTS it clean. Says what the ship is doing so nobody reads the note as a
    # failure. nil when every primary is already clean (print nothing).
    def advisory_message(offenders, at: Time.now)
      list = Array(offenders)
      return nil if list.empty?

      lines = list.flat_map do |o|
        ["  - #{o['repo']}: #{offender_reasons(o).join('; ')}"] +
          rescue_commands(o, at: at).map { |c| "      #{c}" }
      end
      "  ⚠ app primary checkout(s) NOT on a clean `main` — the ship does NOT read them " \
        "(it deploys from its own workspace at the frozen SHA), so this is a NOTE, not a blocker:\n" \
        "#{lines.join("\n")}\n" \
        "    Nothing here is discarded, and nothing is stashed. The commands above park the work on a " \
        "labeled branch if you want the primary clean; a live session's work is safe either way."
    end

    # The ONE primary dependency the ship still has: a GEM artifact is BUILT from
    # the gem repo's primary checkout (`git checkout <frozen>` there, then `gem
    # build`), and `gem build` packages the files it finds ON DISK. So a MODIFIED
    # TRACKED file in a gem primary would be PUBLISHED — a wrong-code release,
    # irreversible (RubyGems forbids re-pushing a version). That is worth an abort;
    # nothing else about a primary is.
    #
    # Narrow ON PURPOSE — tracked modifications only:
    #   * untracked files are NOT packaged (the gemspec's file list is `git
    #     ls-files`), so they are not a correctness hazard and must not gate a ship;
    #   * the branch does not matter (the build detaches to the frozen SHA anyway).
    # An empty result means no gem would package local dirt — safe to build.
    def gem_build_offenders(states)
      Array(states).filter_map do |s|
        files = Array(s["tracked_dirty"] || s[:tracked_dirty]).map(&:to_s).reject(&:empty?)
        files = files.reject { |f| generated_artifact?(f) }
        next if files.empty?

        { "repo" => (s["repo"] || s[:repo]).to_s, "branch" => (s["branch"] || s[:branch]).to_s,
          "on_main" => true, "dirty" => true, "dirty_files" => files }
      end
    end

    # The loud, ACTIONABLE abort for gem_build_offenders. It leads with the stakes
    # (this would publish your uncommitted code) and hands over the exact rescue —
    # never "stash or discard", which is how a live session's work gets destroyed.
    def gem_build_message(offenders, at: Time.now)
      lines = Array(offenders).flat_map do |o|
        files  = Array(o["dirty_files"])
        sample = files.first(5).join(", ")
        more   = files.size > 5 ? " (+#{files.size - 5} more)" : ""
        ["  - #{o['repo']}: modified tracked file(s)#{sample.empty? ? '' : ": #{sample}#{more}"}"] +
          rescue_commands(o, at: at).map { |c| "      #{c}" }
      end
      "ship aborted BEFORE publishing anything — a gem repo's primary has uncommitted changes to TRACKED " \
        "files, and `gem build` packages what is on disk, so those edits would be PUBLISHED to RubyGems " \
        "(a version can never be re-pushed):\n" \
        "#{lines.join("\n")}\n" \
        "  The commands above COMMIT that work to a labeled branch — nothing is stashed and nothing is " \
        "discarded (it may be a live session's). Then re-run `bin/release ship`."
    end

    # The rescue: park a primary's stranded work on a LABELED BRANCH and hand the
    # checkout back clean. Commit, never stash and never discard — the work may
    # belong to a live agent session, and a stash is easy to lose (and its message
    # is only a push-time label). Pure: `at:` is injectable so the branch name is
    # deterministic under test.
    def rescue_commands(offender, at: Time.now)
      repo   = (offender["repo"] || offender[:repo]).to_s
      branch = "rescue/#{repo}-#{at.strftime('%Y%m%d-%H%M%S')}"
      dirty  = offender["dirty"] || offender[:dirty]
      return ["git -C <projects>/#{repo} checkout main   # (clean tree — just leave the review branch)"] unless dirty

      [
        "git -C <projects>/#{repo} switch -c #{branch}   # carries the work over, discards nothing",
        "git -C <projects>/#{repo} add -A && git -C <projects>/#{repo} commit -m 'rescue: stranded primary work'",
        "git -C <projects>/#{repo} switch main   # primary is clean again; the work lives on #{branch}"
      ]
    end

    # --- internals -----------------------------------------------------------

    def offender_reasons(offender)
      reasons = []
      reasons << "on '#{offender['branch']}', not 'main'" unless offender["on_main"]
      if offender["dirty"]
        files  = Array(offender["dirty_files"])
        sample = files.first(5).join(", ")
        more   = files.size > 5 ? " (+#{files.size - 5} more)" : ""
        reasons << "dirty tree#{sample.empty? ? '' : ": #{sample}#{more}"}"
      end
      reasons
    end

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
