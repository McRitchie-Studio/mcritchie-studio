module AgentMessages
  # The floor under bin/dispatcher (docs/agents/agents/steffon/sops/agent-dispatcher.md):
  # deterministic checks, run every minute by AgentDispatcherAlertJob, each
  # announced in Discord ONCE per incident and once more when it clears. Two are
  # floor-wide:
  #
  #   dispatcher_silent  a dispatcher has pinged before, and none has for
  #                      AgentDispatcher::SILENT_AFTER (5 min). Never-installed is
  #                      not an outage: before the first ping this check is quiet.
  #   message_waiting    a routed message has sat `received` for WAIT_LIMIT (10 min)
  #
  # Two more checks are PER CARD: each failing task opens its own incident, named
  # by its slug (AgentMailboxIncident#subject), and resolves on its own.
  #
  #   submitted_unclaimed   a `submitted` card, not blocked, whose builder DoR
  #                         (GateRun "dor") is green, and that has had no review
  #                         claim (TaskReviewClaim) for UNCLAIMED_AFTER (30 min).
  #                         The alert names the review launch line (SOP pr-review,
  #                         single-task entry); it recovers when a claim appears or
  #                         the card leaves submitted.
  #   change_build_refused  the build launcher could not start a chat-sourced
  #                         change card (ChangeBuilds: bin/task begin refused). The
  #                         card stays designed; it recovers when the build starts
  #                         or the card leaves designed.
  #
  # One more floor-wide check reads the dispatcher's harness health, which
  # bin/dispatcher measures on the Mac each beat and carries on its ping:
  #
  #   harness_degraded   the newest live primary's bounded `op whoami` or GitHub
  #                      check has failed on AgentDispatcher::HARNESS_BEATS (5)
  #                      consecutive measured beats
  #
  # The nightly database-backup sweep (DbBackupSweep) opens and resolves its own
  # two kinds on the same table; this announce posts them too, with the sweep's
  # text, so a backup alert reaches the ops channel once, like these.
  #
  # Dedupe is the incidents table (AgentMailboxIncident, one open row per kind):
  # an incident opens on the first failing run, resolves on the first passing
  # one, and its alert_posted_at / recovery_posted_at say what was announced. A
  # failed post is retried on the next run; with no bot token or no
  # ops_channel_id nothing is posted and one log line says so. A recovery is
  # posted only for an incident whose alert was posted.
  #
  # FLAPPING AND ESCALATION. Incidents of one kind (and subject) that reopen
  # within an hour form an episode (AgentMailboxIncident, "EPISODES"). Once an
  # episode has opened FLAP_COUNT (3) times within FLAP_WINDOW (1 hour), Discord
  # gets ONE line, "flapping, N since HH:MM", instead of a line per flap, and one
  # more when it has been quiet for QUIET. A person is told by email (#escalate,
  # AgentFloorMailer, through the outbox to `floor.escalation_email`): ONE email
  # when an incident has stayed open ESCALATE_AFTER (15 min) or its episode is
  # flapping, and ONE when the episode has had nothing open for QUIET (15 min).
  # The email does not depend on Discord being configured.
  class FloorAlert
    WAIT_LIMIT = 10.minutes
    UNCLAIMED_AFTER = 30.minutes
    # What a reader runs to start the review of one card (pr-review.md, "Single-task
    # entry (on submit)"): claim it as Carl, then spawn one Carl subagent.
    HUB = "/Users/alex/projects/mcritchie-studio".freeze
    LOG = "[agent-dispatcher]".freeze
    ESCALATE_AFTER = 15.minutes
    QUIET = 15.minutes
    ZONE = "America/Denver".freeze
    # The name an incident goes by in a flapping line and an email subject.
    LABELS = {
      "dispatcher_silent" => "Agent dispatcher silent",
      "message_waiting" => "Agent mailbox messages waiting",
      "harness_degraded" => "Agent harness degraded (1Password or GitHub)",
      "db_backup_missing" => "Database backup missing",
      "db_backup_sweep_failed" => "Database backup sweep failed",
      "submitted_unclaimed" => "Review not started",
      "change_build_refused" => "Change build not started"
    }.freeze

    Check = Struct.new(:kind, :failing, :detail, :subject, keyword_init: true)

    def initialize(routes: Routes.load, bot: nil, logger: Rails.logger, mailer: AgentFloorMailer)
      @mailer = mailer
      @routes = routes
      @bot = bot
      @logger = logger
    end

    # Returns the checks it ran, for the job's log and the tests.
    def call(now: Time.current)
      AgentDispatcher.prune!(now: now)
      checks = [ dispatcher_check(now), waiting_check(now), harness_check(now) ]
      checks.each { |check| reconcile(check, now) }
      per_card = { "submitted_unclaimed" => unclaimed_checks(now), "change_build_refused" => refused_checks(now) }
      per_card.each { |kind, failing| reconcile_subjects(kind, failing, now) }
      announce(now)
      escalate(now)
      checks + per_card.values.flatten
    end

    # One failing Check per submitted card nobody has started reviewing.
    def unclaimed_checks(now)
      cutoff = now - UNCLAIMED_AFTER
      tasks = Task.where(stage: "submitted", blocked_at: nil)
                  .where("COALESCE(tasks.submitted_at, tasks.updated_at) <= ?", cutoff)
                  .where("NOT EXISTS (SELECT 1 FROM task_review_claims trc WHERE trc.task_slug = tasks.slug " \
                         "AND (trc.claim_expires_at > ? OR trc.acquired_at > ? OR trc.updated_at > ?))", now, cutoff, cutoff)
                  .order(:submitted_at, :id).to_a
      return [] if tasks.empty?

      dor = GateRun.latest_by_key_for_subjects(subject_type: "task", subject_slugs: tasks.map(&:slug))
      tasks.filter_map do |task|
        run = dor.dig(task.slug, "dor")
        next unless run && !run.in_flight? && run.success

        Check.new(kind: "submitted_unclaimed", failing: true, subject: task.slug,
                  detail: { "slug" => task.slug, "submitted_at" => (task.submitted_at || task.updated_at).iso8601,
                            "pr_url" => task.pr_url.presence }.compact)
      end
    end

    # One failing Check per chat-sourced change card the launcher could not start.
    def refused_checks(now)
      Task.where(stage: "designed")
          .where("tasks.metadata->'devops'->'#{ChangeBuilds::KEY}'->>'refused_reason' IS NOT NULL").order(:id)
          .map do |task|
            run = ChangeBuilds.run_of(task)
            Check.new(kind: "change_build_refused", failing: true, subject: task.slug,
                      detail: { "slug" => task.slug, "reason" => run["refused_reason"].to_s[0, 300],
                                "attempts" => run["attempts"].to_i, "max_attempts" => ChangeBuilds.max_attempts })
          end
    end

    def dispatcher_check(now)
      last = AgentDispatcher.last_ping_at
      failing = !last.nil? && last < now - AgentDispatcher::SILENT_AFTER
      newest = AgentDispatcher.primaries.newest_first.first
      # A standby answering for the primary's domains is named, never counted
      # as the primary: the alert still fires, and says who is covering.
      standby = failing ? AgentDispatcher.live_standbys(now: now).newest_first.first : nil
      Check.new(kind: "dispatcher_silent", failing: failing,
                detail: { "last_ping_at" => last&.iso8601, "host" => newest&.host, "worker" => newest&.worker_id,
                          "standby_host" => standby&.host, "power" => newest&.power_source }.compact)
    end

    # The newest primary, while it is live, says op or gh has failed on
    # HARNESS_BEATS consecutive measured beats. A silent dispatcher's harness is
    # unknown, not degraded: dispatcher_silent covers it.
    def harness_check(now)
      row = AgentDispatcher.primaries.newest_first.first
      failing = !row.nil? && row.live?(now: now) && row.harness_degraded?
      return Check.new(kind: "harness_degraded", failing: false, detail: {}) unless failing

      Check.new(kind: "harness_degraded", failing: true,
                detail: { "host" => row.host, "op_ok" => row.op_ok, "gh_ok" => row.gh_ok,
                          "beats" => row.harness_failing_beats, "power" => row.power_source,
                          "checked_at" => row.harness_checked_at&.iso8601 }.compact)
    end

    def waiting_check(now)
      scope = AgentMessage.where(status: "received").where.not(soul_slug: nil)
                          .where("agent_messages.created_at < ?", now - WAIT_LIMIT)
      oldest = scope.order(:id).first
      return Check.new(kind: "message_waiting", failing: false, detail: {}) unless oldest

      paused = AgentDispatcher.mailbox.newest_first.first
      detail = { "count" => scope.count, "oldest_id" => oldest.id, "oldest_soul" => oldest.soul_slug,
                 "oldest_at" => oldest.created_at.iso8601 }
      if paused&.paused?(now: now)
        detail["paused_until"] = paused.paused_until.iso8601
        detail["pause_reason"] = paused.pause_reason
      end
      Check.new(kind: "message_waiting", failing: true, detail: detail.compact)
    end

    # The two incident messages, fixed text so the SOP can quote them.
    def self.alert_text(incident, now: Time.current)
      d = incident.detail
      case incident.kind
      when "dispatcher_silent"
        "Agent dispatcher silent: no ping from bin/dispatcher#{d['host'] ? " on #{d['host']}" : ''} for " \
          "#{minutes_since(d['last_ping_at'], now)} min. " \
          "#{d['standby_host'] ? "The standby on #{d['standby_host']} is answering its domains; the rest wait" : 'Routed Discord messages wait'} " \
          "until it is back.#{d['power'] == 'battery' ? ' Its last ping said the Mac was on battery.' : ''} " \
          "Steffon: SOP agent-dispatcher."
      when "harness_degraded"
        failing = [ ("1Password (`op whoami`)" if d["op_ok"] == false), ("GitHub" if d["gh_ok"] == false) ].compact
        "Agent harness degraded on #{d['host'] || 'the Mac'}: #{failing.join(' and ').presence || 'a check'} failing " \
          "on #{d['beats']} beats in a row (each bounded at 20 s). Agents cannot read secrets or reach GitHub " \
          "until it is fixed; try `OP_CACHE=false op whoami`, then restart 1Password. Steffon: SOP agent-dispatcher."
      when "message_waiting"
        pause = d["paused_until"] ? " The dispatcher is paused until #{d['paused_until']} (#{d['pause_reason'] || 'paused'})." : ""
        "Agent mailbox: #{d['count']} routed message(s) waiting over #{WAIT_LIMIT.inspect}; oldest is ##{d['oldest_id']} " \
          "for #{d['oldest_soul']}, #{minutes_since(d['oldest_at'], now)} min old.#{pause} Steffon: SOP agent-dispatcher."
      when "submitted_unclaimed"
        "Review not started: `#{d['slug']}` has sat submitted with a green DoR and no review claim for " \
          "#{minutes_since(d['submitted_at'], now)} min.#{d['pr_url'] ? " #{d['pr_url']}" : ''} Start it: " \
          "`cd #{HUB} && bin/task review-claim acquire #{d['slug']} --agent carl`, then one Carl subagent " \
          "(SOP pr-review, single-task entry)."
      when "change_build_refused"
        "Change build not started: the launcher could not run bin/task begin for `#{d['slug']}` (#{d['reason']}). " \
          "The card stays designed; attempt #{d['attempts']} of #{d['max_attempts']}. By hand: " \
          "`cd #{HUB} && /Users/alex/projects/.agents/bin/task begin #{d['slug']} --agent pokemon`."
      else DbBackupSweep.alert_text(incident)
      end
    end

    def self.recovery_text(incident, now: Time.current)
      lasted = ((incident.resolved_at || now) - incident.opened_at).div(60).to_i
      case incident.kind
      when "dispatcher_silent" then "Agent dispatcher back: pinging again (incident lasted #{lasted} min)."
      when "harness_degraded" then "Agent harness healthy: 1Password and GitHub checks pass again (incident lasted #{lasted} min)."
      when "message_waiting" then "Agent mailbox clear: no routed message has waited over #{WAIT_LIMIT.inspect} (incident lasted #{lasted} min)."
      when "submitted_unclaimed"
        "`#{incident.subject}` no longer waits for review: a review claim appeared or it left submitted (incident lasted #{lasted} min)."
      when "change_build_refused"
        "`#{incident.subject}` no longer waits for its build: it started or left designed (incident lasted #{lasted} min)."
      else DbBackupSweep.recovery_text(incident, lasted)
      end
    end

    # The flapping line: one per episode, in place of a line per flap.
    def self.flap_text(root, now: Time.current)
      opens = root.flaps(now: now)
      first = root.episode.where(opened_at: (now - AgentMailboxIncident::FLAP_WINDOW)..).minimum(:opened_at)
      "#{label(root)}: flapping, #{opens} since #{clock(first || root.opened_at)}. One line per flap is held " \
        "until it is quiet for #{QUIET.inspect}; Alex is emailed once. Steffon: SOP agent-dispatcher."
    end

    def self.final_text(root, now: Time.current)
      lasted = ((now - root.opened_at) / 60).floor
      "#{label(root)}: steady again, nothing open for #{QUIET.inspect} after #{root.episode.count} openings " \
        "since #{clock(root.opened_at)} (#{lasted} min in all)."
    end

    def self.label(incident)
      base = LABELS.fetch(incident.kind, incident.kind)
      incident.subject.present? ? "#{base} `#{incident.subject}`" : base
    end

    def self.clock(time) = time.in_time_zone(ZONE).strftime("%H:%M %Z")

    def self.minutes_since(iso, now)
      iso.present? ? ((now - Time.zone.parse(iso)) / 60).floor : "?"
    end
    private_class_method :minutes_since

    private

    def reconcile(check, now)
      open = AgentMailboxIncident.open_for(check.kind)
      if check.failing && open.nil?
        AgentMailboxIncident.create!(kind: check.kind, detail: check.detail, opened_at: now)
        @logger.info("#{LOG} incident opened: #{check.kind} #{check.detail.to_json}")
      elsif !check.failing && open
        open.update!(resolved_at: now)
        @logger.info("#{LOG} incident resolved: #{check.kind}")
      end
    rescue ActiveRecord::RecordNotUnique
      nil # a concurrent run opened it first; that run announces it
    end

    # A per-card kind: open one incident per failing slug that has none, keep an
    # open one's detail current, and resolve every open one whose card no longer fails.
    def reconcile_subjects(kind, failing, now)
      open = AgentMailboxIncident.unresolved.where(kind: kind).index_by(&:subject)
      failing.each do |check|
        if (incident = open.delete(check.subject))
          incident.update!(detail: check.detail) if incident.detail != check.detail
          next
        end
        begin
          AgentMailboxIncident.create!(kind: kind, subject: check.subject, detail: check.detail, opened_at: now)
          @logger.info("#{LOG} incident opened: #{kind} #{check.subject}")
        rescue ActiveRecord::RecordNotUnique
          nil # a concurrent run opened it first; that run announces it
        end
      end
      open.each_value do |incident|
        incident.update!(resolved_at: now)
        @logger.info("#{LOG} incident resolved: #{kind} #{incident.subject}")
      end
    end

    def announce(now)
      pending_alerts = AgentMailboxIncident.unresolved.where(alert_posted_at: nil).order(:id).to_a
      pending_recoveries = AgentMailboxIncident.where.not(resolved_at: nil).where.not(alert_posted_at: nil)
                                               .where(recovery_posted_at: nil).order(:id).to_a
      finals = pending_finals
      return if pending_alerts.empty? && pending_recoveries.empty? && finals.empty?

      reason = idle_reason
      if reason
        @logger.info("#{LOG} floor alert not posted (#{reason}): #{(pending_alerts + pending_recoveries + finals).map(&:kind).join(', ')}")
        return
      end

      pending_alerts.each do |incident|
        root = incident.root
        if root.flap_posted_at || incident.flapping?(now: now)
          announce_flap(incident, root, now)
        else
          post(incident, self.class.alert_text(incident, now: now), "a") && incident.update!(alert_posted_at: now)
        end
      end
      pending_recoveries.each do |incident|
        # A flap inside a flapping episode: the flapping line covered it.
        next incident.update!(recovery_posted_at: now) if incident.root.flap_posted_at

        post(incident, self.class.recovery_text(incident, now: now), "r") && incident.update!(recovery_posted_at: now)
      end
      finals.each do |root|
        post(root, self.class.final_text(root, now: now), "fr") && root.update!(final_posted_at: now)
      end
    end

    # The first flap past FLAP_COUNT posts the flapping line on the root; every
    # later flap of the episode is covered by it and posts nothing.
    def announce_flap(incident, root, now)
      if root.flap_posted_at.nil?
        return unless post(root, self.class.flap_text(root, now: now), "f")

        root.update!(flap_posted_at: now)
      end
      incident.reload.update!(alert_posted_at: now)
    end

    def pending_finals
      AgentMailboxIncident.roots.where.not(flap_posted_at: nil).where.not(final_recovery_at: nil)
                          .where(final_posted_at: nil).order(:id).to_a
    end

    # ESCALATION TO A PERSON: ONE email per episode when it escalates, ONE when
    # it is finally quiet, each stamped on the root under its row lock so two
    # overlapping runs cannot both send. A failed send stamps nothing and is
    # tried again next run. Runs whether or not Discord is configured.
    def escalate(now)
      window = now - AgentMailboxIncident::FLAP_WINDOW
      recent = AgentMailboxIncident.where("resolved_at IS NULL OR opened_at >= ?", window).map(&:root_id).uniq
      AgentMailboxIncident.where(id: recent, escalated_at: nil, final_recovery_at: nil).order(:id).each do |root|
        reason = escalation_reason(root, now)
        next unless reason

        send_once(root, :escalated_at, now) { deliver(:escalated, root.id, reason) }
      end
      AgentMailboxIncident.roots.where(final_recovery_at: nil)
                          .where("escalated_at IS NOT NULL OR flap_posted_at IS NOT NULL").order(:id).each do |root|
        next unless quiet?(root, now)

        send_once(root, :final_recovery_at, now) { root.escalated_at ? deliver(:recovered, root.id) : true }
      end
    end

    def escalation_reason(root, now)
      return "flapping" if root.flapping?(now: now)

      open = root.episode.unresolved.first
      "open" if open && open.opened_at <= now - ESCALATE_AFTER
    end

    def quiet?(root, now)
      episode = root.episode
      return false if episode.unresolved.exists?

      last = episode.maximum(:resolved_at)
      !last.nil? && last <= now - QUIET
    end

    def send_once(root, stamp, now)
      root.with_lock do
        next if root.public_send(stamp)

        root.update!(stamp => now) if yield
      end
    rescue StandardError => e
      @logger.warn("#{LOG} floor email for incident #{root.id} not sent (#{e.class}); tried again next run")
    end

    def deliver(action, *args)
      Studio::Email.deliver(@mailer, action, *args, @routes.ops_email, to: @routes.ops_email)
      @logger.info("#{LOG} floor email #{action}: #{args.first} to the ops address")
      true
    end

    def idle_reason
      return "#{DiscordBot::TOKEN_ENV} is unset" if @bot.nil? && !DiscordBot.configured?
      return "config/agent_routes.yml names no discord.ops_channel_id" if @routes.ops_channel_id.nil?

      nil
    end

    def post(incident, text, suffix)
      bot.post_message(@routes.ops_channel_id, content: text[0, 1900], nonce: "ami-#{incident.id}-#{suffix}")
      true
    rescue DiscordBot::Error => e
      @logger.warn("#{LOG} floor alert post failed (#{e.class}); retried next run")
      false
    end

    def bot = (@bot ||= DiscordBot.new)
  end
end
