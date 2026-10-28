module BuildIntake
  # How much Alex answers on /build before asking the visitor to sign in
  # (config/agent_answerers.yml `public_intake`). Checked by BuildIntake::Ingest
  # BEFORE a message is stored as answerable: past a cap the message is stored
  # already answered, with a line from code (#reply), and no model ever runs.
  #
  #   request  answers on one request's thread: turns_per_request signed out,
  #            signed_in_turns_per_request once signed in
  #   ip       signed-out answers from one visitor IP (hashed) per hour, across requests
  #   daily    signed-out answers across ALL public intake per Denver day
  #
  # The claim's SQL guard (Answerers#sql_guard) admits only `received` rows, and
  # this ingest is the only writer of build-thread rows, so a row past a cap is
  # never claimable: it is born `completed`. Two sends racing at the edge may let
  # one extra answer through; the caps are a budget, not a lock.
  #
  # An ANSWER here is any row of a build thread (or, for the :ip and :daily caps,
  # a satellite chat thread) the soul was asked to answer:
  # not held (a bot-shield or unanswered row) and not itself a cap reply.
  class Caps
    ZONE = "America/Denver".freeze
    CAP_SUMMARY = "intake cap".freeze
    # The answers the daily total counts: a signed-out visitor's, and a satellite
    # chat's from an email that is no hub User (AgentChat::Visitor), which costs
    # nothing to make up.
    UNVERIFIED_SQL = "agent_messages.envelope->>'signed_in' = 'false' OR " \
                     "(left(agent_messages.thread_key, ?) = ? AND agent_messages.envelope->>'user_id' IS NULL)".freeze

    REPLIES = {
      request_signed_out: "We've covered a lot, and I'd love to keep going. Sign in to continue: everything " \
                          "you've told me is saved, and your checklist stays right here.",
      request_signed_in: "This conversation has reached its limit. Your answers are saved: finish the " \
                         "checklist and tap Build my app.",
      busy: "I'm answering a lot of people right now. Sign in to keep going: everything you've told me is saved."
    }.freeze

    def initialize(policy: BuildIntake.policy, now: Time.current)
      @policy = policy
      @now = now
    end

    # nil when Alex may answer, else the cap's code (:request, :ip, :daily).
    # No policy (the config has no public_intake) caps nobody: the answerers
    # then hold every signed-out message instead.
    def check(token:, signed_in:, ip_hash: nil)
      return nil unless @policy

      limit = signed_in ? @policy.signed_in_turns_per_request : @policy.turns_per_request
      return :request if answered.where(thread_key: BuildIntake.thread_key(token)).count >= limit
      return nil if signed_in

      public_cap(ip_hash)
    end

    # The caps every signed-out answer shares, /build and the satellite chat
    # (AgentChat::Caps) alike: :ip, :daily, or nil. One budget: a visitor's IP
    # and the day's total count answers on either.
    def public_cap(ip_hash)
      return nil unless @policy
      return :ip if ip_hash.present? && answered.where("agent_messages.envelope->>'ip_hash' = ?", ip_hash)
                                                .where("agent_messages.created_at > ?", @now - 1.hour).count >= @policy.per_ip_per_hour
      return :daily if answered.where(UNVERIFIED_SQL, AgentChat::THREAD_PREFIX.length, AgentChat::THREAD_PREFIX)
                               .where("agent_messages.created_at >= ?", @now.in_time_zone(ZONE).beginning_of_day)
                               .count >= @policy.daily_total

      nil
    end

    # The line the visitor reads at `code`.
    def self.reply(code, signed_in:)
      case code
      when :request then REPLIES[signed_in ? :request_signed_in : :request_signed_out]
      else REPLIES[:busy]
      end
    end

    private

    # The public-intake answers: /build's threads and the satellite chat's
    # (AgentChat::THREAD_PREFIX), so the IP and daily caps are one budget.
    def answered
      AgentMessage.where(channel: "web")
                  .where("left(agent_messages.thread_key, ?) = ? OR left(agent_messages.thread_key, ?) = ?",
                         BuildIntake::THREAD_PREFIX.length, BuildIntake::THREAD_PREFIX,
                         AgentChat::THREAD_PREFIX.length, AgentChat::THREAD_PREFIX)
                  .where.not(status: "held")
                  .where("agent_messages.action_summary IS DISTINCT FROM ?", CAP_SUMMARY)
    end
  end
end
