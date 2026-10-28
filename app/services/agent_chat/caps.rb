module AgentChat
  # How much a satellite chat answers before the hub refuses with 429 (the
  # contract's "capped"; nothing is stored). The numbers are /build's
  # (config/agent_answerers.yml `public_intake`, BuildIntake.policy), so the
  # public costs the same wherever it chats:
  #
  #   signed out   :thread  answers on one anon thread, turns_per_request
  #                :ip      answers from one visitor IP (hashed) per hour, across
  #                         /build and every satellite (BuildIntake::Caps#public_cap)
  #                :daily   signed-out answers across all public intake per Denver day
  #   signed in    :rate    WebIngest::RATE_LIMIT messages in a thread per
  #                         WebIngest::RATE_WINDOW, as the hub's own web chat
  #
  # A signed-in thread is the person's for good, so it takes a rolling rate, not a
  # lifetime count. Two posts racing at the edge may let one extra through; the
  # caps are a budget, not a lock.
  class Caps
    def initialize(policy: BuildIntake.policy, now: Time.current)
      @policy = policy
      @now = now
    end

    # nil when the message may be stored, else the cap's code.
    def check(thread_key:, signed_in:, ip_hash: nil)
      return rate(thread_key) if signed_in
      return nil unless @policy
      return :thread if thread_key && answered(thread_key).count >= @policy.turns_per_request

      BuildIntake::Caps.new(policy: @policy, now: @now).public_cap(ip_hash)
    end

    # The line the app shows at `code`.
    def self.reply(code)
      case code
      when :thread then BuildIntake::Caps::REPLIES[:request_signed_out]
      when :rate then "That's a lot of messages in a short while. Give it a few minutes and try again."
      else BuildIntake::Caps::REPLIES[:busy]
      end
    end

    private

    def rate(thread_key)
      return nil unless thread_key

      recent = AgentMessage.where(channel: "web", thread_key: thread_key)
                           .where("created_at > ?", @now - AgentMessages::WebIngest::RATE_WINDOW).count
      recent >= AgentMessages::WebIngest::RATE_LIMIT ? :rate : nil
    end

    def answered(thread_key)
      AgentMessage.where(channel: "web", thread_key: thread_key).where.not(status: "held")
    end
  end
end
