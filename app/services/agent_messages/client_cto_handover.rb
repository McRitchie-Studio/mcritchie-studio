module AgentMessages
  # Ray's handover to a new client CTO (docs/agents/system/client-cto.md; design:
  # .agents/epics/build-with-xan-design.md, "Build my app"). AppLaunch calls it
  # inside the launch transaction, so a launched app always has its first chat
  # turn and a rolled-back launch has none.
  #
  # It stores ONE `web` AgentMessage in the owner's own chat thread with the
  # app's CTO (`web:<sub>:<user id>`), routed to `client_cto`: its content is
  # Ray's handover line, and it is stored ALREADY ANSWERED with the CTO's
  # opening message (#greeting), which code writes from the launch: the owner's
  # first name, the CTO's, the app's and its address. So the chat opens on the handover
  # and the greeting, never on a bare "typing…", and no model runs for it
  # (.agents/epics/build-with-ray-v2.md, section 6). Nothing here calls a model;
  # the dispatcher never claims the row, and the CTO's first model turn is its
  # answer to the owner's first message, with this greeting in its history.
  #
  # WHY IT IS RELEASED. The owner-only guard (Answerers) holds a message from any
  # role but the owner, and a new client is `public`. This row is not the client's
  # words: code wrote every byte of it, so it carries hold_released_at (actor
  # `app-launch`). Only this row: the client's own next message is answered by
  # the app-owner rule (Answerers#app_owner_thread?) on this thread, and held by
  # their role everywhere else.
  #
  # Idempotent on its external id (one handover per app per owner).
  module ClientCtoHandover
    AUTHOR = "Ray".freeze
    ACTOR = "app-launch".freeze
    VIA = "handover".freeze
    GREETING_SUMMARY = "code greeting".freeze

    module_function

    def line(cto_name) = "Meet #{cto_name}, your CTO. I'll hand you over."

    def external_id(app_slug, user_id) = "handover:#{app_slug}:#{user_id}"

    def handover?(message) = message.envelope.is_a?(Hash) && message.envelope["via"] == VIA

    # The CTO's opening message, from the launch's data alone (task
    # build-launch-handoff, Alex 2026-10-18): first person and by name, it greets
    # the owner by first name, says the CTO is the agent managing the app, that
    # the app is IN LINE to be built and what that means (the address, and the
    # status card's live progress: Prepping, Building, Reviewing, Releasing,
    # Deploying), and what the owner can do here meanwhile. Short, in Alex's
    # plain voice; the plan stays on the summary card the owner just confirmed.
    # Markdown, as every answer.
    #
    # A nameless owner (no first name, no name) is asked for one in the last
    # line (FirstNameAsk::QUESTION; task cto-chat-quality-pass): their reply
    # sets it, so the engine's first-name modal stays off this page.
    #
    # NEVER "building now" (task app-card-stage-labels, Alex 2026-10-19): at
    # launch the task is `designed` and nobody is building it yet; the card
    # (AppDevopsStages) says Building only once a builder holds it. A greeting
    # already stored keeps its words; only new launches read this text.
    def greeting(app_cto, user)
      first = greeting_name(user)
      host = AppRequest.host_for(app_cto.app_slug)
      [
        "Hi #{first || 'there'}, I'm #{app_cto.name}, the agent who'll be managing #{app_cto.app.name}.",
        "It's in line to be built: your brand sheet, the first version of the app, and its home at **#{host}**. " \
        "The card above shows live progress: Prepping until a builder starts, then Building, Reviewing, " \
        "Releasing to a preview link for you, and Deploying once you approve.",
        "Meanwhile, tell me anything you'd like added or changed, or ask about the plan.",
        (FirstNameAsk::QUESTION if first.nil? && FirstNameAsk.ask?(user))
      ].compact.join("\n\n")
    end

    # Whom the greeting names: the owner's first name (users.first_name, which
    # the engine's first-name onboarding collects), else the first word of their
    # name; nil greets "there". Not the email's local part (task
    # build-sign-in-modal looked): "new-builder@" would greet "New", "info@"
    # "Info", and "amcritchie@" "Amcritchie". A new magic-link account has no
    # name yet when the launch writes this, so it is greeted "there".
    def greeting_name(user)
      return nil unless user

      (user.try(:first_name).presence || user.name.to_s.split.first).to_s.strip.presence
    end

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
      greet!(message, app_cto, user, now)
      message
    end

    # Answered in code, posted at once: the page that loads next renders it, so
    # nothing is broadcast (no one is subscribed yet).
    def greet!(message, app_cto, user, now)
      message.update!(status: "completed", completed_at: now, action_summary: GREETING_SUMMARY,
                      response_text: greeting(app_cto, user), reply_nonce: "agentmsg-#{message.id}",
                      reply_external_id: "web:#{message.id}", reply_posted_at: now, reply_status: "posted",
                      run_meta: { "audience" => message.usage_audience, "code_greeting" => true,
                                  FirstNameAsk::META => (true if greeting_name(user).nil? && FirstNameAsk.ask?(user)) }.compact)
      message.record!("completed", actor: ACTOR, detail: { "via" => "code_greeting" })
      message.record!("reply_posted", actor: "web-chat", detail: { "via" => "web_chat" })
    end
  end
end
