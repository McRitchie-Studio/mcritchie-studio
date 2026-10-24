module AgentMessages
  # The floor under bin/dispatcher (docs/agents/agents/steffon/sops/agent-dispatcher.md):
  # two deterministic checks, run every minute by AgentDispatcherAlertJob, each
  # announced in Discord ONCE per incident and once more when it clears.
  #
  #   dispatcher_silent  a dispatcher has pinged before, and none has for
  #                      AgentDispatcher::SILENT_AFTER (5 min). Never-installed is
  #                      not an outage: before the first ping this check is quiet.
  #   message_waiting    a routed message has sat `received` for WAIT_LIMIT (10 min)
  #
  # Dedupe is the incidents table (AgentMailboxIncident, one open row per kind):
  # an incident opens on the first failing run, resolves on the first passing
  # one, and its alert_posted_at / recovery_posted_at say what was announced. A
  # failed post is retried on the next run; with no bot token or no
  # ops_channel_id nothing is posted and one log line says so. A recovery is
  # posted only for an incident whose alert was posted.
  class FloorAlert
    WAIT_LIMIT = 10.minutes
    LOG = "[agent-dispatcher]".freeze

    Check = Struct.new(:kind, :failing, :detail, keyword_init: true)

    def initialize(routes: Routes.load, bot: nil, logger: Rails.logger)
      @routes = routes
      @bot = bot
      @logger = logger
    end

    # Returns the checks it ran, for the job's log and the tests.
    def call(now: Time.current)
      AgentDispatcher.prune!(now: now)
      checks = [ dispatcher_check(now), waiting_check(now) ]
      checks.each { |check| reconcile(check, now) }
      announce(now)
      checks
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
                          "standby_host" => standby&.host }.compact)
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
          "until it is back. Steffon: SOP agent-dispatcher."
      when "message_waiting"
        pause = d["paused_until"] ? " The dispatcher is paused until #{d['paused_until']} (#{d['pause_reason'] || 'paused'})." : ""
        "Agent mailbox: #{d['count']} routed message(s) waiting over #{WAIT_LIMIT.inspect}; oldest is ##{d['oldest_id']} " \
          "for #{d['oldest_soul']}, #{minutes_since(d['oldest_at'], now)} min old.#{pause} Steffon: SOP agent-dispatcher."
      end
    end

    def self.recovery_text(incident, now: Time.current)
      lasted = ((incident.resolved_at || now) - incident.opened_at).div(60).to_i
      case incident.kind
      when "dispatcher_silent" then "Agent dispatcher back: pinging again (incident lasted #{lasted} min)."
      when "message_waiting" then "Agent mailbox clear: no routed message has waited over #{WAIT_LIMIT.inspect} (incident lasted #{lasted} min)."
      end
    end

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

    def announce(now)
      pending_alerts = AgentMailboxIncident.unresolved.where(alert_posted_at: nil).order(:id).to_a
      pending_recoveries = AgentMailboxIncident.where.not(resolved_at: nil).where.not(alert_posted_at: nil)
                                               .where(recovery_posted_at: nil).order(:id).to_a
      return if pending_alerts.empty? && pending_recoveries.empty?

      reason = idle_reason
      if reason
        @logger.info("#{LOG} floor alert not posted (#{reason}): #{(pending_alerts + pending_recoveries).map(&:kind).join(', ')}")
        return
      end

      pending_alerts.each do |incident|
        post(incident, self.class.alert_text(incident, now: now), "a") && incident.update!(alert_posted_at: now)
      end
      pending_recoveries.each do |incident|
        post(incident, self.class.recovery_text(incident, now: now), "r") && incident.update!(recovery_posted_at: now)
      end
    end

    def idle_reason
      return "#{DiscordBot::TOKEN_ENV} is unset" if @bot.nil? && !DiscordBot.configured?
      return "config/agent_routes.yml names no discord.ops_channel_id" if @routes.ops_channel_id.nil?

      nil
    end

    def post(incident, text, suffix)
      bot.post_message(@routes.ops_channel_id, content: text, nonce: "ami-#{incident.id}-#{suffix}")
      true
    rescue DiscordBot::Error => e
      @logger.warn("#{LOG} floor alert post failed (#{e.class}); retried next run")
      false
    end

    def bot = (@bot ||= DiscordBot.new)
  end
end
