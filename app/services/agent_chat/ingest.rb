module AgentChat
  # Turns ONE message a satellite's visitor typed into a `web` AgentMessage on
  # the visitor's (person, soul) thread (AgentChat). From there it is the loop
  # every web chat runs: bin/dispatcher claims it, answers with no tools, and
  # AgentMessages::WebChat.deliver! marks the answer posted; the app polls for it
  # (GET /api/v1/agent_chat/turns), as /build's signed-out page does.
  #
  # The /build intake's twin (BuildIntake::Ingest), with the thread the person's
  # instead of the request's. Everything is derived on the hub:
  #
  #   the soul     a param, but only one config/agent_routes.yml lets THIS app
  #                address (`web: apps:`) and that has a web chat (`web: souls:`)
  #   the thread   AgentChat::Visitor#thread_key!
  #   the person   AgentChat::Visitor#person!
  #   answered?    AgentMessages::Answerers: a person's role, as everywhere, and
  #                the public on the intake soul's chat threads (Answerers#intake?)
  #   the audience always the public, whoever sent it: the person is whoever
  #                an app's credential names by email (MemoryBundle#audience_person)
  #   the app      envelope.app, recorded, never part of the key
  #
  # IN ORDER: the text (trimmed, WebIngest::MAX_LENGTH), the soul, the fold (a
  # signed-in post carrying the visitor's anon token takes that anon thread into
  # the person's), the caps (Capped: 429, nothing stored), then the store:
  # `held` when the answerers do not answer this person here, else `received`.
  class Ingest
    Refused = AgentMessages::WebIngest::Refused

    class NotAvailable < StandardError; end

    class Capped < StandardError
      attr_reader :code

      def initialize(code)
        @code = code
        super(Caps.reply(code))
      end
    end

    def initialize(app:, visitor:, ip: nil, routes: AgentMessages::Routes.current,
                   answerers: AgentMessages::Answerers.current, policy: BuildIntake.policy, now: Time.current)
      @app = app.to_s
      @visitor = visitor
      @ip_hash = ip.present? ? BuildIntake::Ingest.ip_hash(ip) : nil
      @routes = routes
      @answerers = answerers
      @policy = policy
      @now = now
    end

    def soul = @visitor.soul

    # The stored message. Raises Refused (422), NotAvailable (404) or Capped (429).
    def call(text)
      text = text.to_s.gsub(/\r\n?/, "\n").strip
      raise Refused.new("Write a message first.", code: "EMPTY") if text.empty?
      max = AgentMessages::WebIngest::MAX_LENGTH
      raise Refused.new("Keep it under #{max} characters.", code: "TOO_LONG") if text.length > max
      raise NotAvailable, "#{soul} has no web chat for #{@app}" unless AgentChat.available?(@app, soul, routes: @routes)

      thread_key = @visitor.thread_key!
      fold!(thread_key)
      cap = Caps.new(policy: @policy, now: @now).check(thread_key: thread_key, signed_in: @visitor.signed_in?, ip_hash: @ip_hash)
      raise Capped, cap if cap

      store(text, thread_key, @visitor.person!)
    end

    # THE FOLD. A visitor who chatted signed out and then signs in carries their
    # anon token on the first signed-in post; that anon thread's rows move to the
    # person's thread, each with a `thread_folded` event, so the conversation
    # carries on. The anon visitor IS this person, so their anon identity, the
    # rows they wrote and the notes those rows produced move to the person too
    # (AgentPerson#link_identity!, reassign): nothing is orphaned. Idempotent:
    # once moved, the anon thread is empty.
    def fold!(thread_key)
      anon_key = @visitor.anon_thread_key
      return 0 if anon_key.nil? || anon_key == thread_key

      ids = AgentMessage.where(channel: "web", thread_key: anon_key).order(:id).pluck(:id)
      return 0 if ids.empty?

      AgentMessage.transaction(requires_new: true) do
        AgentMessage.where(id: ids).update_all(thread_key: thread_key, updated_at: @now)
        if AgentPersonIdentity.exists?(platform: "web", external_id: @visitor.anon_ref)
          @visitor.person!.link_identity!(platform: "web", external_id: @visitor.anon_ref, reassign: true)
        end
        AgentMessage.where(id: ids).find_each do |row|
          row.record!("thread_folded", actor: "agent-chat", detail: { "from" => anon_key, "to" => thread_key, "app" => @app })
        end
      end
      ids.size
    end

    private

    def store(text, thread_key, person)
      attrs = { channel: "web", external_id: "chat:#{SecureRandom.uuid}", guild_id: nil, channel_ref: AgentChat::CHANNEL_REF,
                thread_key: thread_key, author_ref: @visitor.author_ref, author_name: @visitor.author_name,
                person: person, content: text, mentions: {}, sent_at: @now, soul_slug: soul, routed_by: "chat",
                envelope: { "via" => "agent_chat", "app" => @app, "user_id" => @visitor.user&.id,
                            "signed_in" => @visitor.signed_in?, "ip_hash" => @ip_hash }.compact }
      AgentMessage.transaction(requires_new: true) do
        # The probe carries no person: built with one, it would join the
        # person's unsaved `messages` and fail their next save.
        probe = AgentMessage.new(attrs.except(:person))
        held = !@answerers.allowed?(person, message: probe)
        message = AgentMessage.create!(attrs.merge(status: held ? "held" : "received"))
        message.record!("received", actor: "agent-chat", detail: { "author" => message.author_name, "app" => @app,
                                                                   "user_id" => @visitor.user&.id }.compact)
        message.record!("routed", actor: "router", detail: { "matched" => "the #{@app} agent chat", "soul" => soul,
                                                             "routed_by" => "chat" })
        if held
          message.record!("held", actor: "answerers", detail: { "reason" => @answerers.held_reason(person), "person_id" => person&.id }.compact)
        end
        message
      end
    end
  end
end
