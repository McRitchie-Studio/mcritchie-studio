module AgentMessages
  # Xan's handover to a new client CTO (docs/agents/system/client-cto.md; design:
  # .agents/epics/build-with-xan-design.md, "Build my app"). AppLaunch calls it
  # inside the launch transaction, so a launched app always has its first chat
  # turn and a rolled-back launch has none.
  #
  # It stores ONE `web` AgentMessage in the owner's own chat thread with the
  # app's CTO (`web:<sub>:<user id>`), routed to `client_cto`: its content is
  # Xan's handover line, and the dispatcher answers it as any web message, so the
  # CTO's reply (the greeting, which restates the plan) arrives over the chat's
  # Turbo stream like every other answer. Nothing here calls a model.
  #
  # WHY IT IS RELEASED. The owner-only guard (Answerers) holds a message from any
  # role but the owner, and a new client is `public`. This row is not the client's
  # words: code wrote every byte of it, so it carries hold_released_at (actor
  # `app-launch`) and the claim guard passes it. Only this row: the client's own
  # next message is answered by the app-owner rule (Answerers#app_owner_thread?)
  # on this thread, and held by their role everywhere else.
  #
  # Idempotent on its external id (one handover per app per owner).
  module ClientCtoHandover
    AUTHOR = "Xan".freeze
    ACTOR = "app-launch".freeze
    VIA = "handover".freeze

    module_function

    def line(cto_name) = "Meet #{cto_name}, your CTO. I'll hand you over."

    def external_id(app_slug, user_id) = "handover:#{app_slug}:#{user_id}"

    def handover?(message) = message.envelope.is_a?(Hash) && message.envelope["via"] == VIA

    def enqueue!(app_cto:, user:, now: Time.current)
      external = external_id(app_cto.app_slug, user.id)
      existing = AgentMessage.find_by(channel: "web", external_id: external)
      return existing if existing

      person = WebIngest.person_for(user)
      message = AgentMessage.create!(
        channel: "web", external_id: external, guild_id: nil, channel_ref: app_cto.app_slug,
        thread_key: WebChat.thread_key(app_cto.app_slug, user.id), author_ref: user.id.to_s, author_name: AUTHOR,
        person: person, content: line(app_cto.name), mentions: {}, sent_at: now,
        soul_slug: AppCto::SOUL, routed_by: "chat", status: "received", hold_released_at: now, hold_released_by: ACTOR,
        envelope: { "via" => VIA, "app" => app_cto.app_slug, "user_id" => user.id }
      )
      message.record!("received", actor: ACTOR, detail: { "author" => AUTHOR, "user_id" => user.id })
      message.record!("routed", actor: "router", detail: { "matched" => "the #{app_cto.app_slug} CTO handover",
                                                           "soul" => AppCto::SOUL, "routed_by" => "chat" })
      message.record!("hold_released", actor: ACTOR, detail: { "reason" => "code-written handover", "person_id" => person&.id }.compact)
      message
    end
  end
end
