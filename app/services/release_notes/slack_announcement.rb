module ReleaseNotes
  # A shipped release, told on Slack (Alex McRitchie, 2026-10-30: "send a general
  # message about the release and application specific messages about the
  # release ... the specific agents can run production smoke test upon
  # deployment and give feedback in Slack"). Run on the hub by
  # Release::Conductor.announce_release, from `bin/release announce` (which the
  # cycle runs once prod verify is green).
  #
  #   1. ONE summary in the general channel (agent_media.yml release_posts.general,
  #      #agents-general), as Mason: the release, each app with its emoji and the
  #      SHA production runs, and every card with its task and PR links.
  #   2. ONE post per shipped app in that app's channel (agent_routes.yml
  #      slack.channels, by the repo's name), as the channel's own soul (its
  #      default_soul when it may answer there, else release_posts.app_soul,
  #      Steffon): the cards that shipped there, and that a smoke test follows.
  #   3. The smoke verdict, IN THAT POST'S THREAD, as the same soul. Green is one
  #      line; red names what failed with its evidence and @-mentions Alex
  #      McRitchie (agent_routes.yml slack.owner_user_id).
  #
  # WHY THE SMOKE IS NOT A MAILBOX RUN. A dispatched soul answers with
  # `claude --safe-mode --tools ""` (AgentMailbox::Responder): it can read
  # nothing and run nothing, so it cannot smoke an app. The checks run in code
  # on the conductor's machine (`bin/release announce`: /up, home, the deployed
  # SHA; the hub adds its post-ship seal) and arrive here as `smoke`; this posts
  # the verdict in the soul's own voice. What the mailbox does get is the
  # THREAD: each app post is stored as a completed AgentMessage keyed to its
  # Slack thread, so when Alex McRitchie answers in it, SlackIngest routes his
  # message to that soul, and the thread cap has his message to count from.
  #
  # EXACTLY ONCE, NEVER FATAL. Every post is keyed (SlackPost idempotency_key
  # release:<slug>:…), so a re-run posts only what never went out and never
  # re-posts an ambiguous one. Every failure is caught, logged (ErrorLog) and
  # reported in the result; nothing here raises into a ship.
  class SlackAnnouncement
    TASK_BASE_URL = Formatter::PRODUCTION_TASK_BASE_URL
    GENERAL_SOUL = "mason".freeze
    APP_SOUL = "steffon".freeze
    GENERAL_CHANNEL = "agents".freeze

    Result = Struct.new(:posts, keyword_init: true) do
      def count(status) = posts.count { |p| p[:status] == status }
      def sent = count("sent")
      def failed = count("failed")

      # "Slack posts: 3 sent / 0 failed" (+ already, suppressed, skipped when any).
      def line
        extra = %w[already suppressed skipped].filter_map { |s| (n = count(s)).positive? ? "#{n} #{s}" : nil }
        "Slack posts: #{sent} sent / #{failed} failed#{extra.any? ? " (#{extra.join(', ')})" : ''}"
      end

      def to_h = { line: line, sent: sent, failed: failed, posts: posts }
    end

    # smoke: { repo => { "checks" => [{ "path", "url", "code", "ok" }],
    #                    "sha" => { "sha", "ok", "reason" } } }, from the
    # conductor's machine. An app with no entry is reported as not smoked (red).
    def initialize(release:, smoke: {}, slack: Media::Slack.new, config: Media::Config.current,
                   routes: AgentMessages::SlackRoutes.current)
      @release = release
      @smoke = (smoke || {}).to_h.deep_stringify_keys
      @slack = slack
      @config = config
      @routes = routes
    end

    def call(dry_run: false)
      posts = []
      posts << general_post(dry_run)
      app_groups.each do |group|
        posts.concat(app_posts(group, dry_run))
      end
      Result.new(posts: posts)
    end

    # --- what is said --------------------------------------------------------

    # Each repo the release carries, in catalog order: [{ repo:, name:, emoji:,
    # app: true|false, sha:, tasks: [Task] }].
    def groups
      @groups ||= begin
        by_repo = Hash.new { |h, k| h[k] = [] }
        @release.ordered_members.each do |task|
          repos = task.release_repos.presence || [ task.release_repo ].compact
          repos.each { |repo| by_repo[repo.to_s] << task }
        end
        order = AppCatalog.apps.map(&:slug) + AppCatalog.libraries.map(&:slug)
        by_repo.keys.sort_by { |repo| order.index(repo) || order.size }.map do |repo|
          entry = AppCatalog.app(repo)
          { repo: repo, name: entry&.name || repo, emoji: AppCatalog.emoji_map[repo] || "📦",
            app: entry.present?, url: entry&.production_url, sha: sha_for(repo), tasks: by_repo[repo].uniq }
        end
      end
    end

    def app_groups = groups.select { |g| g[:app] }

    def general_text
      lines = [ ":rocket: *#{esc(@release.slug)}* shipped to production" ]
      groups.each do |g|
        head = "#{g[:emoji]} *#{esc(g[:name])}*"
        head += " `#{g[:sha][0, 7]}`" if g[:sha].present?
        head += " · <#{g[:url]}|prod>" if g[:url].present?
        head += " (library)" unless g[:app]
        lines << head
        g[:tasks].each { |task| lines << "   • #{card_line(task, g[:repo], label: task.slug)}" }
      end
      lines.join("\n")
    end

    def app_text(group)
      head = "#{group[:emoji]} *#{esc(@release.slug)}* shipped here"
      head += " · `#{group[:sha][0, 7]}`" if group[:sha].present?
      lines = [ head ]
      group[:tasks].each { |task| lines << "• #{card_line(task, group[:repo], label: task.title.presence || task.slug)}" }
      lines << ":test_tube: Running a production smoke test; the result follows in this thread."
      lines.join("\n")
    end

    # Green: one line. Red: what failed, with its evidence, and Alex McRitchie.
    def smoke_text(group)
      verdict = smoke_verdict(group)
      if verdict[:green]
        parts = verdict[:checks].map { |c| "#{c['label']} #{c['code']}" }
        line = ":white_check_mark: smoke green: #{parts.join(', ')}, #{verdict[:checks].size} pages checked"
        line += " · runs `#{verdict[:sha][0, 7]}`" if verdict[:sha].present?
        line += " · seal :large_green_circle:" if verdict[:seal]&.green?
        return line
      end

      owner = @routes.owner_user_id
      lines = [ ":red_circle: smoke red#{owner ? " <@#{owner}>" : ''}" ]
      lines.concat(verdict[:failures].map { |f| "• #{f}" })
      lines.join("\n")
    end

    def smoke_verdict(group)
      entry = @smoke[group[:repo]]
      seal = group[:repo] == hub_repo ? @release.smoke_seal : nil
      unless entry.is_a?(Hash)
        return { green: false, checks: [], sha: nil, seal: seal,
                 failures: [ "no smoke result reached the hub for #{esc(group[:repo])} (no production URL checked)" ] }
      end

      checks = Array(entry["checks"]).select { |c| c.is_a?(Hash) }.map do |c|
        c.merge("label" => c["path"].to_s == "/" ? "home" : c["path"].to_s)
      end
      sha = entry["sha"].is_a?(Hash) ? entry["sha"] : nil
      failures = checks.reject { |c| c["ok"] }.map do |c|
        "#{esc(c['label'])} → #{esc(c['code'].presence || 'no answer')} (#{esc(c['url'])})"
      end
      failures << "no page was checked" if checks.empty?
      failures << "production is not proven at `#{esc(sha['sha'].to_s[0, 7])}`: #{esc(sha['reason'])}" if sha && !sha["ok"]
      failures << "post-ship seal red: #{esc(seal.summary)}" if seal&.red?
      { green: failures.empty?, checks: checks, sha: sha && sha["ok"] ? sha["sha"].to_s : nil, seal: seal,
        failures: failures }
    end

    # --- who says it where ---------------------------------------------------

    def general_home
      spec = @config.release_posts["general"] || {}
      name = spec["channel"].to_s.presence || GENERAL_CHANNEL
      Media::Home.new(medium: "slack", channel: name, spec: @config.channel("slack", name),
                      source: "release_posts:general", fell_from: [])
    end

    def general_soul = (@config.release_posts["general"] || {})["soul"].to_s.presence || GENERAL_SOUL

    def app_home(repo)
      id = @routes.channel_id_named(repo)
      return nil if id.blank?

      Media::Home.new(medium: "slack", channel: repo, spec: { "id" => id }, source: "release_posts:app:#{repo}",
                      fell_from: [])
    end

    # The channel's own soul when it serves and may answer there, else Steffon.
    def app_soul(channel_id)
      fallback = @config.release_posts["app_soul"].to_s.presence || APP_SOUL
      soul = @routes.default_soul(channel_id)
      soul.present? && @routes.answers?(soul) && @routes.cleared?(channel_id, soul) ? soul : fallback
    end

    private

    def general_post(dry_run)
      home = general_home
      return outcome("general", nil, "failed", "no general channel in config/agent_media.yml") unless home.channel?

      deliver("general", home, soul: general_soul, text: general_text, key: key(home.channel_id, "general"),
                               dry_run: dry_run)
    end

    def app_posts(group, dry_run)
      repo = group[:repo]
      home = app_home(repo)
      return [ outcome(repo, nil, "skipped", "no Slack channel named #{repo} in config/agent_routes.yml") ] if home.nil?

      soul = app_soul(home.channel_id)
      text = app_text(group)
      post = deliver(repo, home, soul: soul, text: text, key: key(home.channel_id, "app"), dry_run: dry_run)
      return [ post ] if dry_run || post[:ts].blank?

      thread_row!(home.channel_id, post[:ts], soul, group, text)
      smoke = deliver("#{repo} smoke", home, soul: soul, text: smoke_text(group), thread_ts: post[:ts],
                                             key: key(home.channel_id, "smoke"), dry_run: dry_run)
      [ post, smoke ]
    end

    def deliver(what, home, soul:, text:, key:, dry_run:, thread_ts: nil)
      return outcome(what, home, "dry_run", nil, soul: soul, text: text) if dry_run

      posted = @slack.post(home, text: text, soul: soul, thread_ts: thread_ts, kind: "release", key: key,
                                 release_slug: @release.slug)
      status = posted["already_posted"] ? "already" : "sent"
      outcome(what, home, status, nil, soul: soul, ts: posted["ts"].to_s)
    rescue Media::Slack::Suppressed => e
      outcome(what, home, "suppressed", e.message, soul: soul)
    rescue StandardError => e
      # Never into the ship: logged, reported, and the next post still runs.
      Rails.logger.warn("[release-slack] #{what} for #{@release.slug} failed (non-fatal): #{e.class}: #{e.message}")
      ErrorLog.capture!(e) rescue nil # rubocop:disable Style/RescueModifier
      outcome(what, home, "failed", "#{e.class.name.demodulize}: #{e.message}", soul: soul)
    end

    def outcome(what, home, status, error, soul: nil, ts: nil, text: nil)
      { what: what, channel: home&.channel_id, soul: soul, status: status, ts: ts.presence, error: error&.to_s&.slice(0, 300),
        text: text }.compact
    end

    # The app post, held by the mailbox as a completed message in its own Slack
    # thread: SlackIngest routes a reply in this thread to `soul`, and the
    # soul's memory of the thread starts with what it said here. Idempotent on
    # the post's own Slack id (channel:ts).
    def thread_row!(channel_id, ts, soul, group, text)
      external_id = "#{channel_id}:#{ts}"
      return if AgentMessage.exists?(channel: "slack", external_id: external_id)

      now = Time.current
      message = AgentMessage.create!(
        channel: "slack", external_id: external_id, guild_id: @routes.team_id, channel_ref: channel_id,
        thread_key: "slack:#{channel_id}:#{ts}", author_name: "Release conductor",
        content: "Release #{@release.slug} shipped to #{group[:name]}: #{group[:tasks].map(&:slug).join(', ')}. " \
                 "Tell Alex McRitchie what shipped and run the production smoke test.",
        soul_slug: soul, routed_by: "release", status: "completed", sent_at: now, completed_at: now,
        response_text: text, reply_external_id: ts, reply_status: "posted", reply_posted_at: now,
        envelope: { "origin" => "release", "release_slug" => @release.slug, "app" => group[:repo] }
      )
      message.record!("received", actor: "release", detail: { "release" => @release.slug, "app" => group[:repo] })
      message.record!("reply_posted", actor: "slack-bot", detail: { "reply_id" => ts })
    rescue StandardError => e
      Rails.logger.warn("[release-slack] thread row for #{group[:repo]} not stored (non-fatal): #{e.class}: #{e.message}")
    end

    def key(channel_id, what) = "release:#{@release.slug}:#{channel_id}:#{what}"

    def card_line(task, repo, label:)
      pr = Array(task.release_pr_urls.to_h[repo]).first.presence || task.devops_field("pr_url").presence
      line = "<#{TASK_BASE_URL}/#{task.slug}|#{link_label(label)}>"
      line += " · <#{pr}|#{pr_label(pr)}>" if pr.to_s.match?(%r{\Ahttps://})
      line
    end

    def pr_label(url) = (n = url.to_s[%r{/pull/(\d+)}, 1]) ? "PR ##{n}" : "PR"

    # What production runs for this repo: the ship's deployed_apps record, else
    # the SHA `main` moved to, else the hub's deployed_sha.
    def sha_for(repo)
      meta = @release.metadata || {}
      deployed = meta.dig("deployed_apps", repo)
      sha = deployed.is_a?(Hash) ? deployed["sha"].to_s : ""
      sha = meta.dig("shipped_shas", repo).to_s if sha.empty?
      sha = @release.deployed_sha.to_s if sha.empty? && repo == hub_repo
      sha
    end

    def hub_repo = "mcritchie-studio"

    def esc(text) = Media::Slack::Format.escape(text)

    def link_label(text) = esc(text).tr("|", "¦")
  end
end
