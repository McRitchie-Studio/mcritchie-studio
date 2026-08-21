class Release
  # The producer/consumer repo registry for the Deploy workflow — a thin,
  # dependency-light reader over config/release_repos.yml. Classifies an
  # ecosystem repo as a :gem (published to RubyGems, the producer) or an :app
  # (deployed, the consumer), which is what lets a release ship producer-first.
  #
  # See config/release_repos.yml for the schema. Memoized for the process; call
  # .reload! after editing the YAML in dev.
  module Repos
    module_function

    CONFIG_PATH = Rails.root.join("config", "release_repos.yml")

    def config
      @config ||= (YAML.load_file(CONFIG_PATH) || {})
    end

    def reload!
      @config = nil
      config
    end

    # :gem (producer), :app (consumer), or :unknown (not in the registry).
    def kind(repo)
      return :gem if gem?(repo)
      return :app if app?(repo)

      :unknown
    end

    def gem?(repo)
      gem_repos.include?(repo.to_s)
    end

    def app?(repo)
      app_repos.include?(repo.to_s)
    end

    def gem_repos
      config.fetch("gems", {}).keys
    end

    def app_repos
      config.fetch("apps", {}).keys
    end

    # The registry entry for a repo, whichever half it lives in. `gem_meta` and
    # `app_meta` each answer for one half and nil for the other, so a caller that
    # only wants a shared key (`ladder`) had to try both and pick.
    def meta(repo)
      gem_meta(repo) || app_meta(repo)
    end

    # "three-rung" (accepted → release → main), "dormant", or nil when the repo is
    # not registered. Declared per repo in config/release_repos.yml.
    def ladder(repo)
      meta(repo)&.dig("ladder")
    end

    # Every registered repo — gem or app — that actually walks the three-rung
    # ladder, in registry order (gems first, then apps).
    #
    # This is the set a ladder-status surface asks about: a `dormant` repo (rolio)
    # has no live rungs to report, and a repo absent from the registry has no
    # ladder at all. Deriving it here rather than hardcoding a list means a new
    # satellite joins the moment it is registered, and leaves when it is retired.
    def three_rung_repos
      (gem_repos + app_repos).select { |repo| ladder(repo) == "three-rung" }
    end

    # The gem's registry metadata (version_file, gemspec, release_check, …) or
    # nil when the repo isn't a registered gem.
    def gem_meta(repo)
      config.fetch("gems", {})[repo.to_s]
    end

    # A gem is SELF-GATED when the registry gives it its own pre-publish gate
    # (a non-empty `release_check`): its own suite IS the release-candidate
    # verdict, so it can be its OWN release candidate — published to RubyGems
    # with no consuming app to QA it through. Both registered gems declare
    # `release_check: bin/release-check` and are self-gated as of 2026-08-20, when
    # solana-studio grew a suite runner alongside its Rails engine — it was the
    # standing counter-example before that. A gem with NO release_check still
    # requires a consuming app in the sweep; read the registry rather than this
    # comment for who is which.
    #
    # bin/release mirrors this predicate standalone (it reads the registry
    # through RELEASE_REPOS, never through Rails) — keep the two in step.
    def self_gated_gem?(repo)
      gem_meta(repo)&.fetch("release_check", nil).to_s.strip.present?
    end

    # The app's registry metadata (prod_deploy adapter, optional qa_deploy, …) or
    # nil when the repo isn't a registered app.
    def app_meta(repo)
      config.fetch("apps", {})[repo.to_s]
    end

    # The production-deploy adapter for an app (a hash with a `strategy` key —
    # git_push_heroku or repo_script — plus its strategy-specific fields) or nil
    # when the repo isn't a registered app.
    def prod_deploy(repo)
      app_meta(repo)&.fetch("prod_deploy", nil)
    end

    # The pre-prod test command an app's MERGED release branch must pass before
    # the irreversible prod deploy (registry `test_cmd`), or nil when unset. The
    # hub declares `bin/rails test`; satellites leave it unset because their own
    # repo_script deploy (e.g. bin/deploy) runs their suite — see the YAML caveat.
    def test_cmd(repo)
      app_meta(repo)&.fetch("test_cmd", nil)
    end

    # Avi's pre-QA gate command (registry `qa_test_cmd`) — the integration
    # tier `bin/release prepare` runs on origin/release BEFORE any QA deploy —
    # or nil when unset (the repo self-gates at ship / its own deploy; the gate
    # skips it). Registered apps carry the integration SUBSET, never the full
    # suite — see the WHAT-to-register note in config/release_repos.yml.
    def qa_test_cmd(repo)
      app_meta(repo)&.fetch("qa_test_cmd", nil)
    end

    # The qa-server key for an app — its optional `qa_deploy.app` override, else
    # the repo slug. Always returns a string for any repo (qa targets are keyed
    # by slug by default), so callers don't special-case the common case.
    def qa_app(repo)
      app_meta(repo)&.dig("qa_deploy", "app") || repo.to_s
    end

    # The sibling checkout path for a repo — gem repos live next to this app at
    # the projects root, so resolve relative to the app root's parent.
    def repo_path(repo)
      Rails.root.parent.join(repo.to_s)
    end

    # The version a gem would publish, read from its version_file. Returns nil
    # when the repo isn't a gem, has no version_file, or the file isn't reachable
    # (e.g. on a prod box where the sibling repo isn't checked out) — the caller
    # treats nil as "resolve it locally at publish time".
    def gem_version(repo)
      meta = gem_meta(repo)
      return nil unless meta

      version_file = meta["version_file"].to_s
      return nil if version_file.empty?

      path = repo_path(repo).join(version_file)
      return nil unless File.exist?(path)

      extract_version(File.read(path))
    end

    # Pull a semantic version out of either `VERSION = "x.y.z"`
    # (lib/studio/version.rb) or `spec.version = "x.y.z"` (a gemspec).
    def extract_version(contents)
      contents.to_s[/version\s*=\s*["']([\w.\-]+)["']/i, 1]
    end
  end
end
