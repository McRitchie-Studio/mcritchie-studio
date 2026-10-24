class Release
  # Which registered apps run on studio-engine, and which of them a release did
  # NOT carry.
  #
  # THE DRIFT THIS EXISTS FOR. A release re-locks a published gem only into the
  # apps it sweeps (app_groups: the apps with a member card), because those are
  # the apps it QA's and deploys. An engine app with no card in a release was
  # never re-locked, so it fell one release further behind every time the engine
  # published without it. Measured 2026-10-24: moms-app locked 0.101.0 and rantly
  # 0.87.0 while the hub locked 0.112.0, 14 and 34 releases behind.
  #
  # The fix keys off the REGISTRIES, not the membership: every app the catalog
  # (config/apps.yml) flags `engine: true` and live, that the release registry
  # (config/release_repos.yml) lists as a three-rung app. `cardless` is that set
  # minus the apps the release swept, which the ship re-locks to the final on
  # their `accepted` (bin/release.rb#relock_cardless_consumers).
  #
  # The engine flag stays in config/apps.yml, its one home; the release registry
  # does not copy it, so the two cannot disagree. test/lib/app_registry_test.rb
  # already holds the two files to each other.
  #
  # IO-free, like Ladder: it takes the parsed registry and the catalog's entries
  # (anything answering slug, engine and live?) and returns slugs.
  module EngineConsumers
    module_function

    # Every live engine app the release registry can sweep, in registry order.
    def all(registry, catalog_apps)
      flagged = catalog_apps.select { |app| app.engine == true && app.live? }.map { |app| app.slug.to_s }
      apps = registry.fetch("apps", {}) || {}
      Ladder.sweepable(registry).select { |repo| apps.key?(repo) && flagged.include?(repo) }
    end

    # The engine apps this release does not carry: the ones only the cardless
    # re-lock reaches.
    def cardless(registry, catalog_apps, swept)
      carried = Array(swept).map(&:to_s)
      all(registry, catalog_apps).reject { |repo| carried.include?(repo) }
    end
  end
end
