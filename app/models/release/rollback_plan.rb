class Release
  # THE PLAN behind `bin/release rollback [<release>]`: which SHA each app goes back
  # to, how each app's deploy strategy gets it there, and every reason to refuse.
  #
  # A rollback is a DEPLOY of the previous shipped SHA, never a ref move. `main`,
  # `release` and `accepted` stay where the ship left them, so the release's code is
  # still on `main` and the next ship redeploys it unless a revert lands on
  # `accepted` first. The plan says so in its notes.
  #
  # Per strategy (config/release_repos.yml `prod_deploy`):
  #   github_actions   the hub: dispatch the same prod-deploy workflow ship uses with
  #                    `sha=<previous>`. The workflow force-pushes that SHA to Heroku
  #                    and hard-gates on /up, exactly as it does for a ship.
  #   git_push_heroku  force-push the previous SHA to the app's Heroku remote. Force,
  #                    because the Heroku branch is ahead of it; the remote is a
  #                    deploy target, not a source of truth.
  #   repo_script      turf-monster: `heroku rollback v<N>` to the Heroku release that
  #                    deployed the previous SHA. The repo's own script cannot do it:
  #                    it pushes without force, so Heroku rejects an older commit, and
  #                    its IDL allow-list dance runs only forward. Heroku's rollback
  #                    restores that release's slug AND its config vars. It is the same
  #                    mechanism turf's bin/deploy uses when its own smoke fails.
  #
  # THE CONFIG REVERT, and why heroku rollback is still the strategy. Rolling back to
  # vN reverts every config var set since vN, add-on vars included. The alternative,
  # a new release of vN's slug over today's config (the Platform API's
  # `POST /apps/:app/releases {slug}`), keeps the config but can strand the slug:
  # turf pins the IDL the slug boots against in EXPECTED_IDL_HASH, a config var its
  # forward deploy tightens to the NEW hash, so the old slug would fail turf's boot
  # verification. The pin and the slug travel together only in a rollback. So the
  # plan reads the Heroku releases newer than vN, lists every config change the
  # rollback reverts by its release description (which names keys, never values),
  # refuses `--mode auto` when there is any, and under `--mode ask` shows them and
  # asks for a separate confirm.
  #
  # THE SCHEMA REFUSAL. Migrations run in each app's Procfile release phase, so the
  # database is already at the shipped schema; old code against a newer schema is
  # not a rollback. When the shipped SHA carries db/migrate files the previous SHA
  # lacks, the plan refuses and names them. The comparison is injected (bin/release
  # diffs git trees by SHA, never a checkout).
  #
  # GEMS publish rather than deploy. A published gem cannot be unpublished, and a
  # yank is not a rollback, so the plan names each gem version and leaves it on
  # RubyGems: a rolled-back app runs the version its previous SHA's Gemfile.lock pins.
  #
  # Pure and Rails-free (like SealTree and ShipSequence), so bin/release can
  # `require_relative` it and every decision is unit-tested without a board.
  class RollbackPlan
    HUB = "mcritchie-studio".freeze
    MIGRATE_DIR = "db/migrate".freeze
    STRATEGIES = %w[github_actions git_push_heroku repo_script].freeze
    MODES = %w[ask auto].freeze
    # Heroku names a release created by a git push `Deploy <sha8>`; ShipSequence
    # reads the same shape to confirm an inline deploy landed.
    DEPLOY_DESCRIPTION = /\ADeploy\s+([0-9a-f]{7,40})\b/i

    AppStep = Struct.new(:repo, :strategy, :adapter, :from_sha, :to_sha, :to_release,
                         :migrations, :heroku_version, :heroku_current, :config_reverts,
                         :already_live, keyword_init: true)
    GemNote = Struct.new(:repo, :version, keyword_init: true)

    attr_reader :release_slug, :apps, :gems, :notes, :refusals

    # How a rollback takes production authority. A dry run, or no authority at all,
    # is a PLAN: it prints and deploys nothing. `--mode ask` confirms at a prompt and
    # `--mode auto` (or `--yes`) proceeds, as `bin/release ship --mode` does. `timed`
    # is refused: it waits out an operator window, and a rollback is the thing an
    # operator runs because they are already at the keyboard.
    def self.authority(explicit:, assume_yes:, dry:)
      return "plan" if dry

      mode = explicit.to_s.strip
      unless mode.empty?
        if mode == "timed"
          raise ArgumentError, "rollback does not take --mode timed: a rollback is run by an operator who is present. " \
                               "Use --mode ask (confirm at the prompt) or --mode auto."
        end
        raise ArgumentError, "unknown rollback mode #{mode.inspect} (ask|auto)" unless MODES.include?(mode)

        return mode
      end
      assume_yes ? "auto" : "plan"
    end

    # The config changes a rollback to `version` reverts: every release newer than it
    # that is not a `Deploy` and not a rollback to that same version, as
    # "v305 Set ACTIVE_STORAGE_BACKEND config vars", oldest first. Heroku's
    # descriptions name the keys a release changed, never their values.
    def self.config_changes_since(releases, version)
      rows = Array(releases).select { |r| r.is_a?(Hash) && (r["version"] || r[:version]).to_i > version.to_i }
      rows.sort_by { |r| (r["version"] || r[:version]).to_i }.filter_map do |r|
        text = (r["description"] || r[:description]).to_s.strip
        next if DEPLOY_DESCRIPTION.match?(text)
        next if rollback_to?(text, version)

        "v#{(r['version'] || r[:version]).to_i} #{text}"
      end
    end

    def self.rollback_to?(description, version) = description.to_s.match?(/\ARollback to v#{version.to_i}\b/i)

    # The newest release version in a `heroku releases` read, or 0.
    def self.newest_version(releases)
      Array(releases).select { |r| r.is_a?(Hash) }.map { |r| (r["version"] || r[:version]).to_i }.max.to_i
    end

    # Did the release `heroku rollback` created (the first version newer than
    # `after`) go live? :succeeded once it is current and succeeded, :failed when
    # Heroku says failed, :pending while it has not appeared or is still releasing.
    def self.release_phase_verdict(releases, after:)
      row = Array(releases).select { |r| r.is_a?(Hash) && (r["version"] || r[:version]).to_i > after.to_i }
                           .min_by { |r| (r["version"] || r[:version]).to_i }
      return :pending unless row

      status = (row["status"] || row[:status]).to_s
      return :failed if status == "failed"
      return :succeeded if status == "succeeded" && (row["current"] || row[:current]) == true

      :pending
    end

    # The Heroku release version (an Integer) that deployed `sha`, newest first, or
    # nil. Only a SUCCEEDED `Deploy <sha>` row counts; the current release is
    # skipped, since rolling back to what is already serving is not a rollback.
    def self.heroku_version_for(releases, sha)
      target = sha.to_s.strip.downcase
      return nil if target.length < 7

      rows = Array(releases).select { |r| r.is_a?(Hash) }
      rows = rows.sort_by { |r| -(r["version"] || r[:version]).to_i }
      row = rows.find do |r|
        next false if (r["current"] || r[:current]) == true
        next false unless (r["status"] || r[:status]).to_s == "succeeded"

        match = DEPLOY_DESCRIPTION.match((r["description"] || r[:description]).to_s)
        match && target.start_with?(match[1].downcase)
      end
      row && (row["version"] || row[:version]).to_i
    end

    # target:   the release to roll back, as bin/release reads it: "slug", "state",
    #           "deployed_sha", "shipped_shas" ({repo => sha}), "repos" (repo_plan),
    #           "rolled_back" (metadata, present once a rollback completed).
    # history:  releases shipped BEFORE it, newest first: "slug", "shipped_shas",
    #           "deployed_sha".
    # later:    the slug of a release shipped AFTER it, or nil.
    # shipping: the slug of a release whose production deploy is in flight, or nil.
    def self.build(target:, history:, later: nil, shipping: nil, hub: HUB)
      new(target: target, history: history, later: later, shipping: shipping, hub: hub)
    end

    def initialize(target:, history:, later:, shipping:, hub:)
      @target = target.is_a?(Hash) ? target : {}
      @history = Array(history).select { |r| r.is_a?(Hash) }
      @hub = hub
      @release_slug = @target["slug"].to_s
      @apps = []
      @gems = []
      @notes = []
      @refusals = []
      refuse_release_state(later, shipping)
      plan_repos if @refusals.empty?
    end

    def refused? = !@refusals.empty?

    # Fill each app's migration check. `lister.call(repo, shipped_sha, previous_sha)`
    # returns the db/migrate paths the shipped tree adds over the previous one, or
    # nil when the trees could not be compared — which refuses (fail closed).
    def check_migrations!(lister)
      @apps.each do |app|
        added = lister.call(app.repo, app.from_sha, app.to_sha)
        if added.nil?
          @refusals << "#{app.repo}: could not compare #{short(app.from_sha)} with #{short(app.to_sha)} — " \
                       "the schema check fails closed"
          next
        end
        app.migrations = Array(added).map(&:to_s).select { |p| p.start_with?("#{MIGRATE_DIR}/") }.sort
        next if app.migrations.empty?

        @refusals << "#{app.repo}: the shipped SHA #{short(app.from_sha)} carries #{app.migrations.size} migration(s) " \
                     "the previous SHA #{short(app.to_sha)} lacks — #{app.migrations.join(', ')}. The release phase " \
                     "already ran them, so old code would meet a newer schema. Fix forward, or write and ship a " \
                     "down migration first."
      end
      self
    end

    # Resolve each repo_script app's Heroku release. `reader.call(heroku_app)`
    # returns `heroku releases --json`, or nil when the read was skipped (a dry
    # run), which leaves the version to the real run instead of refusing.
    def resolve_heroku_versions!(reader)
      @apps.select { |a| a.strategy == "repo_script" }.each do |app|
        heroku_app = app.adapter["heroku_app"].to_s
        releases = reader.call(heroku_app)
        next if releases.nil?

        app.heroku_version = self.class.heroku_version_for(releases, app.to_sha)
        unless app.heroku_version
          @refusals << "#{app.repo}: no succeeded Heroku release on #{heroku_app} deployed #{short(app.to_sha)} " \
                       "(`heroku releases --app #{heroku_app}`) — nothing to roll back to"
          next
        end
        app.heroku_current = self.class.newest_version(releases)
        current = releases.find { |r| r.is_a?(Hash) && (r["current"] || r[:current]) == true } || {}
        app.already_live = (current["status"] || current[:status]).to_s == "succeeded" &&
                           self.class.rollback_to?(current["description"] || current[:description], app.heroku_version)
        app.config_reverts = app.already_live ? [] : self.class.config_changes_since(releases, app.heroku_version)
      end
      self
    end

    # Every config change the rollback would revert, as "<repo>: v305 Set …".
    def config_reverts
      @apps.flat_map { |a| Array(a.config_reverts).map { |c| "#{a.repo}: #{c}" } }
    end

    # Why `mode` may not run this plan, or nil. `auto` never reverts config: a
    # config change since the target release needs an operator to read it.
    def authority_refusal(mode)
      return nil unless mode.to_s == "auto" && config_reverts.any?

      "the rollback would revert config set since the target release (#{config_reverts.join('; ')}). " \
        "--mode auto and --yes never revert config; run --mode ask, read the list, and confirm it"
    end

    # The command each app's redeploy runs, as the plan prints it.
    def command_for(app)
      case app.strategy
      when "github_actions"
        "gh workflow run #{app.adapter['workflow']} -f sha=#{app.to_sha}"
      when "git_push_heroku"
        "git -C #{app.repo} push --force #{remote_for(app)} #{app.to_sha}:refs/heads/#{branch_for(app)}"
      when "repo_script"
        version = app.heroku_version ? "v#{app.heroku_version}" : "<the release that deployed #{short(app.to_sha)}>"
        "heroku rollback #{version} --app #{app.adapter['heroku_app']}"
      end
    end

    def remote_for(app) = app.adapter["remote"].to_s.empty? ? "heroku" : app.adapter["remote"].to_s
    def branch_for(app) = app.adapter["branch"].to_s.empty? ? "main" : app.adapter["branch"].to_s

    # Where to smoke /up after the redeploy, or "" when the strategy smokes itself
    # (the hub's workflow hard-gates on /up) or the registry names no URL.
    def smoke_url_for(app)
      return "" if app.strategy == "github_actions"

      app.adapter["smoke_url"].to_s.strip
    end

    # THE DEVOPS BACKFILL STEP (rollback-prints-devops-backfill). Hub code older than
    # devops-keys-become-columns writes pr_url, branch, approval_status and session_id
    # only as devops keys, so a rollback across it leaves those columns stale, and the
    # production-deploy SOP says to re-run the backfill rake after rolling forward.
    # A one-off step must not become permanent noise, so it prints only while it can
    # apply: the hub range adds the columns migration (that rollback is refused by the
    # schema check, so the step tells whoever rolls back by hand what they owe), or the
    # hub's target tree carries the rake (the command exists in the code being
    # deployed). Once the rake is deleted and no range crosses the migration, the line
    # is gone. `rake_in_target` is read by bin/release from git objects; nil = unread.
    # Returns the line, or nil.
    DEVOPS_COLUMNS_MIGRATION = "20261006150000".freeze
    DEVOPS_BACKFILL_RAKE = "lib/tasks/devops_columns_backfill.rake".freeze

    def devops_backfill_step(rake_in_target:)
      hub = @apps.find { |a| a.repo == @hub }
      return nil unless hub

      crosses = Array(hub.migrations).any? { |m| File.basename(m).start_with?("#{DEVOPS_COLUMNS_MIGRATION}_") }
      return nil unless crosses || rake_in_target == true

      why = crosses ? "the hub range adds the devops columns migration #{DEVOPS_COLUMNS_MIGRATION}" :
                      "the hub target #{short(hub.to_sha)} carries #{DEVOPS_BACKFILL_RAKE}"
      "devops backfill (#{why}): once you roll forward, run `heroku run bin/rails tasks:backfill_devops_columns " \
        "--app #{@hub}` and re-run it until it reports 0 still diverge(s); it is idempotent"
    end

    # The printed plan, one line per fact.
    def lines
      out = ["rollback plan for #{@release_slug}:"]
      @apps.each do |app|
        out << "  #{app.repo} (#{app.strategy}): #{short(app.from_sha)} → #{short(app.to_sha)} " \
               "(shipped by #{app.to_release})"
        out << "      #{command_for(app)}"
        if app.strategy == "repo_script"
          if app.already_live
            out << "      already live: the current Heroku release is the rollback to v#{app.heroku_version} — skipped"
          elsif app.config_reverts.nil?
            out << "      config changes since the target release: not read under --dry-run"
          elsif app.config_reverts.empty?
            out << "      reverts no config: no config change since v#{app.heroku_version}"
          else
            app.config_reverts.each { |c| out << "      REVERTS CONFIG: #{c}" }
          end
          out << "      then wait for the new Heroku release to succeed"
        end
        url = smoke_url_for(app)
        out << "      then smoke #{url}/up" unless url.empty?
      end
      @gems.each do |gem|
        out << "  #{gem.repo}#{gem.version.to_s.empty? ? '' : " #{gem.version}"}: stays published on RubyGems — a " \
               "published gem cannot be unpublished, and a yank is not a rollback. Each rolled-back app runs the " \
               "version its previous SHA's Gemfile.lock pins."
      end
      @notes.each { |note| out << "  note: #{note}" }
      out
    end

    # { "from" => {repo => sha}, "to" => {repo => sha}, "to_release" => {repo => slug} }
    # for the rollback release event and the release's rolled_back metadata.
    def evidence
      {
        "from" => @apps.to_h { |a| [a.repo, a.from_sha] },
        "to" => @apps.to_h { |a| [a.repo, a.to_sha] },
        "to_release" => @apps.to_h { |a| [a.repo, a.to_release] }
      }
    end

    # The red seal's summary once the rollback lands.
    def seal_summary
      moves = @apps.map { |a| "#{a.repo} #{short(a.from_sha)} → #{short(a.to_sha)}" }.join("; ")
      "rolled back: #{moves}"
    end

    private

    def refuse_release_state(later, shipping)
      if @release_slug.empty?
        @refusals << "no shipped release to roll back"
        return
      end
      state = @target["state"].to_s
      unless state == "shipped"
        @refusals << "#{@release_slug} is #{state.empty? ? 'unknown' : state}, not shipped — an unshipped candidate " \
                     "comes off with `bin/release eject`, not a rollback"
      end
      if later.to_s.strip != ""
        @refusals << "#{later} shipped after #{@release_slug}; roll back #{later} first (a rollback restores the " \
                     "release before the one it names)"
      end
      if shipping.to_s.strip != ""
        @refusals << "#{shipping} is deploying to production now; let that ship finish or abort first"
      end
      rolled = @target["rolled_back"]
      return unless rolled.is_a?(Hash) && !rolled.empty?

      @refusals << "#{@release_slug} was already rolled back#{rolled['at'] ? " at #{rolled['at']}" : ''}"
    end

    def plan_repos
      shipped = hash_of(@target["shipped_shas"])
      Array(@target["repos"]).select { |g| g.is_a?(Hash) }.each do |group|
        repo = group["repo"].to_s
        if group["kind"].to_s == "gem"
          version = Array(group["members"]).map { |m| m.is_a?(Hash) ? m["version"] : nil }.compact.first
          @gems << GemNote.new(repo: repo, version: version)
        else
          plan_app(repo, group["prod_deploy"], shipped)
        end
      end
      @apps = order(@apps)
      @refusals << "#{@release_slug} deployed no app this command can roll back" if @apps.empty? && @refusals.empty?
      @notes << "main is untouched: a rollback is a deploy, not a ref move. The release's code stays on main and " \
                "accepted, so the next ship redeploys it unless a revert lands on accepted first."
      @notes << "data is not rolled back: rows written and post-deploy backfills run since the release stay."
      return unless @apps.any? { |a| a.strategy == "repo_script" }

      @notes << "heroku rollback restores that release's config vars as well as its slug; every config change " \
                "since then reverts with it (listed per app above). --mode auto refuses when there is any."
    end

    def plan_app(repo, adapter, shipped)
      adapter = adapter.is_a?(Hash) ? adapter : {}
      strategy = adapter["strategy"].to_s
      if strategy.empty?
        @notes << "#{repo} has no production deploy target — nothing to roll back"
        return
      end
      unless STRATEGIES.include?(strategy)
        @refusals << "#{repo}: unknown prod_deploy strategy #{strategy.inspect}"
        return
      end
      if strategy == "repo_script" && adapter["heroku_app"].to_s.strip.empty?
        @refusals << "#{repo}: a repo_script app needs `heroku_app` in config/release_repos.yml to roll back"
        return
      end

      from = shipped[repo].to_s
      from = @target["deployed_sha"].to_s if from.empty? && repo == @hub
      if from.empty?
        @refusals << "#{repo}: no shipped SHA recorded on #{@release_slug} — cannot tell what is live"
        return
      end

      to, to_release = previous_for(repo)
      if to.empty?
        @refusals << "#{repo}: no earlier shipped release records a SHA for it — nothing to roll back to"
        return
      end
      if to == from
        @notes << "#{repo} is already at #{short(to)} in the previous release — nothing to redeploy"
        return
      end

      @apps << AppStep.new(repo: repo, strategy: strategy, adapter: adapter, from_sha: from, to_sha: to,
                           to_release: to_release, migrations: [])
    end

    # The newest earlier release that recorded a SHA for `repo`. A release that did
    # not touch the repo carries no entry, so the walk goes back past it.
    def previous_for(repo)
      @history.each do |release|
        # A release that was itself rolled back never ran in production afterwards
        # as the known-good state; going back to it would redeploy bad code.
        rolled = release["rolled_back"]
        next if rolled.is_a?(Hash) && !rolled.empty?

        sha = hash_of(release["shipped_shas"])[repo].to_s
        sha = release["deployed_sha"].to_s if sha.empty? && repo == @hub
        return [sha, release["slug"].to_s] unless sha.empty?
      end
      ["", ""]
    end

    # Satellites first, the hub last: the hub is the board this command records
    # through, so it stays on the code that recorded the start until the end.
    def order(apps)
      hub, rest = apps.partition { |a| a.repo == @hub }
      rest + hub
    end

    def hash_of(value) = value.is_a?(Hash) ? value.transform_keys(&:to_s) : {}
    def short(sha) = sha.to_s[0, 8]
  end
end
