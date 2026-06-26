class Release
  # Host resolution for `bin/prod-smoke <app>` — the production base URL the
  # read-only @qa-readonly suite smokes after a ship.
  #
  # SINGLE SOURCE OF TRUTH (and the host-nuance resolution): the seal smokes the
  # EXACT host the ship's `/up` hard-gate already trusts — config/release_repos.yml
  # `apps.<app>.prod_deploy.smoke_url` (https://app.mcritchie.studio for the hub).
  # So a green `/up` gate and a green seal can never disagree because of host
  # routing. config/devops_test_suites.yml's `production_url` is the apex
  # (https://mcritchie.studio) — a branded alias of the SAME dyno (both 200 on /up,
  # no redirect), but it is NOT the gate's host, so it is deliberately NOT the
  # resolution source here. Fallbacks: qa_environments.yml `production_url` (also
  # app.mcritchie.studio for the hub), then DEFAULT_BASE_URL.
  #
  # Pure + IO-free (like Release::Cli / Release::ShipSequence): it takes the loaded
  # YAML hashes in and returns a URL string out, so bin/prod-smoke can
  # `require_relative` it with no Rails boot and the resolution stays unit-tested.
  module ProdSmoke
    module_function

    DEFAULT_BASE_URL = "https://app.mcritchie.studio".freeze

    # The production base URL for <app>, resolved release_repos → qa_environments →
    # default. `release_repos` / `qa_environments` are the loaded YAML hashes (the
    # WHOLE file, including the top-level keys).
    def base_url_for(app, release_repos: {}, qa_environments: {})
      app = app.to_s
      from_release_repos(app, release_repos) ||
        from_qa_environments(app, qa_environments) ||
        DEFAULT_BASE_URL
    end

    # config/release_repos.yml → apps.<app>.prod_deploy.smoke_url (the gate's host).
    def from_release_repos(app, cfg)
      dig_presence(cfg, "apps", app, "prod_deploy", "smoke_url")
    end

    # config/qa_environments.yml → qa_environments.<app>.production_url.
    def from_qa_environments(app, cfg)
      dig_presence(cfg, "qa_environments", app, "production_url")
    end

    # dig that tolerates a nil/non-hash node and returns nil for a blank leaf.
    def dig_presence(cfg, *path)
      node = cfg
      path.each do |key|
        return nil unless node.is_a?(Hash)

        node = node[key]
      end
      value = node.to_s.strip
      value.empty? ? nil : value
    end
  end
end
