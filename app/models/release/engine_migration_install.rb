# frozen_string_literal: true

# `class Release`, not `module` — Release is an ActiveRecord model, and reopening
# it as a module raises TypeError before a single test runs.
class Release
  # Installing a published ENGINE's migrations into each consumer, during the
  # sweep, in the same commit that bumps that consumer's lock.
  #
  # WHY THE SWEEP DOES THIS AT ALL. `<engine>:install:migrations` is a MANUAL step
  # Rails hands the consuming app, and every consumer asserts it was taken
  # (EnginePinContractTest). The sweep publishes the gem to RubyGems —
  # irreversible — and commits the lock bump BEFORE the pre-QA gate runs those
  # suites, so an engine release that adds a migration reddens every consumer
  # after the point of no return. Measured on studio-engine PR 169: that assertion
  # fired in all three consumer lanes, five commits running.
  #
  # THIS FILE IS THE DECISIONS; bin/release.rb runs the commands. That split is
  # not tidiness — it is the review finding that produced it. The first cut put
  # the whole thing in the shell, and its probe was FAIL-OPEN: any non-zero
  # `bin/rails -T` read as "this gem is not an engine", so a workspace whose
  # bundle was not installed skipped the step silently, printing nothing, while
  # the SOP told the operator migrations were handled. Two reviewers reproduced
  # it. Every branch below is now a value a test can hold.
  module EngineMigrationInstall
    module_function

    # Rails' own convention for an engine's railtie namespace — `studio-engine`
    # installs with `studio_engine:install:migrations`. Whether that task EXISTS
    # is asked, never assumed: most published gems are not engines.
    def install_task(gem_name)
      return nil if gem_name.to_s.strip.empty?

      "#{gem_name.to_s.tr('-', '_')}:install:migrations"
    end

    # What `bin/rails -T <task>` just told us. THE DISTINCTION THIS EXISTS FOR:
    #
    #   * exit 0, task listed        -> :present     install it
    #   * exit 0, nothing listed     -> :absent      not an engine; skip, silently
    #   * NON-ZERO                   -> :unbootable  the app did not boot at all
    #
    # The third case is the one that shipped wrong. `bundle lock` resolves without
    # INSTALLING, and nothing else in the sweep installs the version it just
    # pushed, so `require "bundler/setup"` raises Bundler::GemNotFound and rails
    # exits 1 — indistinguishable, to a fail-open probe, from a gem that simply
    # ships no migrations. A missing master.key and a broken bundle land here too.
    # The caller ABORTS on :unbootable: in a function whose whole design is
    # fail-closed, "I could not tell" must never read as "nothing to do".
    def probe_verdict(ok:, output:, task:)
      return :unbootable unless ok
      return :absent if task.to_s.empty?

      output.to_s.include?(task) ? :present : :absent
    end

    # The database the schema dump may use, derived from the one the gate would
    # use for this repo.
    #
    # Postgres apps get a THROWAWAY database of their own — named for the repo and
    # this process, so two sweeps (or a sweep and a developer) can never collide,
    # and never the shared `<app>_test`. A SQLITE app (rolio) gets nil, which
    # leaves DATABASE_URL unset so the app's own database.yml points at a file
    # inside the workspace — private by construction. Handing a postgres:// URL to
    # a SQLite app is a live trap this repo already warns about elsewhere, which
    # is why the base URL comes from gate_database_url rather than being built by
    # hand.
    def throwaway_database_url(base_url:, repo:, pid:)
      return nil if base_url.to_s.strip.empty?

      uri = URI.parse(base_url)
      uri.path = "/#{repo.to_s.tr('-', '_')}_release_schema_#{pid}"
      uri.to_s
    rescue URI::InvalidURIError
      nil
    end

    # Is this `db/schema.rb` diff one the sweep may commit unreviewed?
    #
    # Installing a migration should ADD a table and move the version stamp.
    # Anything else — a dropped table, a changed column, a rewritten index — means
    # the consumer's committed schema was already out of step with its own
    # migrations, and the sweep would be smuggling that drift into a release
    # commit labelled "bump gem for QA". Fail closed and let a person look.
    #
    # The version line is the one deletion that is always expected, since the
    # dumper rewrites `define(version: ...)` in place.
    def schema_dump_safe?(diff_text)
      removals = diff_text.to_s.lines.select do |line|
        line.start_with?("-") && !line.start_with?("---")
      end

      removals.all? { |line| line.include?("ActiveRecord::Schema") && line.include?("define(version:") }
    end
  end
end
