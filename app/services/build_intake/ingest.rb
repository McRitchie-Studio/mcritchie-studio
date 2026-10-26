module BuildIntake
  # Turns ONE message a visitor typed into the /build chat into an AgentMessage
  # for Alex on the request's thread, `web:build:<token>` (the CTO chat's twin is
  # AgentMessages::WebIngest). From there it is the same loop: the dispatcher
  # claims it, answers with no tools, and AgentMessages::WebChat.deliver! marks
  # the answer posted; the page polls for it (a signed-out visitor has no
  # /cable socket).
  #
  # WHO MAY SEND is possession of the request: its secret token, and once the
  # request belongs to an account, that account (BuildController). This class
  # derives everything else on the server:
  #
  #   the soul    BuildIntake.soul (Alex), never a param
  #   the thread  web:build:<token>
  #   the person  signed in: the user's web person (WebIngest.person_for); signed
  #               out: the request's own visitor person, web identity
  #               "build:<token>", role public. Never matched by name
  #   answered?   AgentMessages::Answerers: the owner as everywhere, and anyone
  #               on this thread through public intake, within BuildIntake::Caps
  #
  # IN ORDER: the text (trimmed, WebIngest::MAX_LENGTH), then the store: `held`
  # when the bot shield flagged it (`bot_reason`) or the answerers do not answer
  # it; at a cap, stored ALREADY ANSWERED with the cap line (no model runs);
  # else `received`. Idempotent on (channel, external_id), as WebIngest.
  class Ingest
    Refused = AgentMessages::WebIngest::Refused
    CLIENT_ID = AgentMessages::WebIngest::CLIENT_ID

    def initialize(request:, user: nil, ip: nil, answerers: AgentMessages::Answerers.current,
                   policy: BuildIntake.policy, now: Time.current)
      @request = request
      @user = user
      @ip_hash = ip.present? ? self.class.ip_hash(ip) : nil
      @answerers = answerers
      @policy = policy
      @now = now
    end

    # An IP, keyed and cut, so the caps can count it and the row never holds it.
    def self.ip_hash(ip)
      OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, "build-intake:#{ip}")[0, 24]
    end

    # The stored message (new, or the one this client id already stored).
    def call(text, client_id: nil, bot_reason: nil)
      text = text.to_s.gsub(/\r\n?/, "\n").strip
      raise Refused.new("Write a message first.", code: "EMPTY") if text.empty?
      if text.length > AgentMessages::WebIngest::MAX_LENGTH
        raise Refused.new("Keep it under #{AgentMessages::WebIngest::MAX_LENGTH} characters.", code: "TOO_LONG")
      end

      key = BuildIntake.thread_key(@request.token)
      external_id = "build:#{@request.token}:#{client_id.to_s.match?(CLIENT_ID) ? client_id : SecureRandom.uuid}"
      existing = AgentMessage.find_by(channel: "web", external_id: external_id)
      return existing if existing&.thread_key == key

      external_id = "build:#{@request.token}:#{SecureRandom.uuid}" if existing
      person = @user ? AgentMessages::WebIngest.person_for(@user) : visitor_person
      attrs = { channel: "web", external_id: external_id, guild_id: nil, channel_ref: BuildIntake::CHANNEL_REF,
                thread_key: key, author_ref: @user ? @user.id.to_s : "build:#{@request.token}",
                author_name: (@user&.display_name.presence || "Visitor").to_s[0, 200], person: person,
                content: text, mentions: {}, sent_at: @now, soul_slug: BuildIntake.soul, routed_by: "chat",
                envelope: { "via" => "build_chat", "request" => @request.token, "user_id" => @user&.id,
                            "signed_in" => @user.present?, "ip_hash" => @ip_hash }.compact }
      message = store(attrs, person, bot_reason)
      AgentMessages::WebChat.deliver!(message) if message.status == "completed"
      message
    rescue ActiveRecord::RecordNotUnique
      AgentMessage.find_by!(channel: "web", external_id: external_id)
    end

    # The signed-out visitor's person for this request: one per request, found
    # again by its web identity. Public, like every new person.
    def visitor_person(attempt: 1)
      external_id = "build:#{@request.token}"
      identity = AgentPersonIdentity.find_by(platform: "web", external_id: external_id)
      return identity.person if identity

      AgentPerson.transaction(requires_new: true) do
        person = AgentPerson.create!(display_name: "Visitor")
        person.identities.create!(platform: "web", external_id: external_id, display_name: "Visitor")
        person
      end
    rescue ActiveRecord::RecordNotUnique
      raise if attempt > 1

      visitor_person(attempt: attempt + 1)
    end

    private

    def store(attrs, person, bot_reason)
      AgentMessage.transaction(requires_new: true) do
        probe = AgentMessage.new(attrs)
        answered = @answerers.allowed?(person, message: probe)
        cap = bot_reason || !answered ? nil : Caps.new(policy: @policy, now: @now).check(token: @request.token, signed_in: @user.present?, ip_hash: @ip_hash)
        message = AgentMessage.create!(attrs.merge(status: bot_reason || !answered ? "held" : "received"))
        message.record!("received", actor: "build-chat", detail: { "author" => message.author_name, "user_id" => @user&.id }.compact)
        message.record!("routed", actor: "router", detail: { "matched" => "the /build intake chat", "soul" => message.soul_slug,
                                                             "routed_by" => "chat" })
        if bot_reason
          message.record!("bot_shield", actor: "board", detail: { "reason" => bot_reason })
        elsif !answered
          message.record!("held", actor: "answerers", detail: { "reason" => @answerers.held_reason(person), "person_id" => person&.id }.compact)
        elsif cap
          capped!(message, cap)
        end
        message
      end
    end

    # Answered in code at a cap: completed with the cap line, no run, queued for
    # delivery (the caller marks it posted once the transaction commits).
    def capped!(message, code)
      message.update!(status: "completed", completed_at: @now, action_summary: Caps::CAP_SUMMARY,
                      response_text: Caps.reply(code, signed_in: @user.present?),
                      reply_nonce: "agentmsg-#{message.id}", reply_status: "queued",
                      run_meta: { "audience" => message.usage_audience, "intake_capped" => code.to_s })
      message.record!("intake_capped", actor: "board", detail: { "cap" => code.to_s, "signed_in" => @user.present? })
    end
  end
end
