class Release
  # Pure decision logic for the multi-repo `bin/release ship` ("Run Deployment").
  #
  # Like Release::GemfileRepin this is deliberately IO-free: no git, no gem push,
  # no bundle, no network. It takes plans/listings/text in and returns
  # symbols/booleans/arrays out, so the git + gem + bundle orchestration stays in
  # bin/release and ALL the sequencing/version/ordering decisions stay here, unit
  # tested. (bin/release `require`s this file directly — it has no Rails deps.)
  #
  # The four decisions a multi-repo ship turns on:
  #   * which prod-deploy adapter handles a repo            (strategy_handler)
  #   * the hub-before-satellites app order                 (ordered_app_groups)
  #   * which of a consumer's gems still need re-pinning     (gems_to_repin)
  #   * whether a gem version must be published / is yanked  (publish_needed?/yanked?)
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
    # RubyGems versions listing: an array of { "number" =>, "yanked" => } hashes
    # (the /api/v1/versions/<gem>.json shape) OR a plain array of version strings
    # (all treated as live, the `gem list` shape).
    def publish_needed?(version, remote_versions)
      !live_numbers(remote_versions).include?(version.to_s)
    end

    # Was `version` published and then YANKED? RubyGems permanently forbids
    # re-pushing a yanked number, so this is an abort-and-bump signal, NOT an
    # idempotent skip. Detectable only from the rich (hash) listing; a plain
    # string listing carries no yanked flag, so this is always false for it.
    def yanked?(version, remote_versions)
      Array(remote_versions).any? do |entry|
        version_number(entry) == version.to_s && yanked_flag?(entry)
      end
    end

    # --- internals -----------------------------------------------------------

    def group_repo(group)
      (group[:repo] || group["repo"]).to_s
    end

    # The non-yanked version numbers in a RubyGems listing.
    def live_numbers(remote_versions)
      Array(remote_versions).reject { |entry| yanked_flag?(entry) }.map { |entry| version_number(entry) }
    end

    # The version string out of either a {"number" => "x"} hash or a bare "x".
    def version_number(entry)
      (entry.is_a?(Hash) ? (entry["number"] || entry[:number]) : entry).to_s
    end

    # The yanked flag out of a hash entry (false for a bare string).
    def yanked_flag?(entry)
      return false unless entry.is_a?(Hash)

      flag = entry.key?("yanked") ? entry["yanked"] : entry[:yanked]
      [true, "true", 1, "1"].include?(flag)
    end
  end
end
