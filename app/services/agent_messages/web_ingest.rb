module AgentMessages
  # Turns ONE message a signed-in user typed into an app's CTO chat
  # (/applications/:slug/chat, CtoChatsController) into an AgentMessage on the
  # `web` channel (docs/agents/system/agent-message-loop.md, "Web chat"). From
  # there it is the same loop as Discord and email: the dispatcher claims it,
  # answers with no tools, and AgentMessageReplyJob delivers the answer, here
  # over the chat's Turbo stream (AgentMessages::WebChat).
  #
  # WHO MAY SEND is the controller's gate: the app's owner (AppMembership) or an
  # admin, else 404. This class trusts only what the session vouches for: the
  # USER. Everything else is derived on the server:
  #
  #   the soul    the app's CTO (config/cto_reports.yml), and only when the
  #               `web:` block of config/agent_routes.yml lists it; never a
  #               param, so a chat for one app can never reach another app's CTO
  #   the thread  `web:<app slug>:<user id>`, one per user per app: the THREAD
  #               layer and the proposal scope never cross users or apps
  #   the person  the user's own web identity (platform `web`, external id the
  #               user id), else the person an operator already linked to this
  #               user (agent_people.user_id: Alex's hub user is the owner's),
  #               else a new `public` person for the user. Never matched by name
  #   answered?   the person's role (config/agent_answerers.yml), exactly as on
  #               Discord and email, OR the app-owner rule
  #               (Answerers#app_owner_thread?): a person whose hub user owns
  #               THIS app is answered on THIS thread, as a client of the app.
  #               Anyone else is `held`, and so is that owner on any other
  #               app's thread, on Discord, and by email
  #   the cap     a message answered only by the app-owner rule, while the
  #               app's owner meter (AgentUsage.owner_meter) is spent, is
  #               stored ALREADY ANSWERED with AgentUsage.cap_reply: no model runs
  #
  # IN ORDER: the text (trimmed, MAX_LENGTH; it may be empty when files are
  # attached), the soul, the files (Attachments.resolve!: images and PDFs, at
  # most Attachments::MAX_FILES, each under its size cap and uploaded by this
  # user to this app's chat), the owner's go / no / change: on a proposal in this
  # thread (ProposalConfirm, before any model, as on Discord; never for a message
  # that carries files), then the store: `held` past RATE_LIMIT in RATE_WINDOW or
  # for a role the agents do not answer, else `received`, with the files attached
  # in the same transaction. A nameless owner's first message after the CTO
  # asked for their name (FirstNameAsk) that gives a name or a skip is stored
  # answered in code, and the name saved.
  #
  # Idempotent on (channel, external_id): the form carries a client id per send,
  # so a double submit stores one row.
  class WebIngest
    MAX_LENGTH = 4000
    RATE_LIMIT = 30
    RATE_WINDOW = 1.hour
    CLIENT_ID = /\A[A-Za-z0-9_-]{8,64}\z/

    class Refused < StandardError
      attr_reader :code

      def initialize(message, code:)
        super(message)
        @code = code
      end
    end

    def initialize(user:, cto:, routes: Routes.current, answerers: Answerers.current, now: Time.current)
      @user = user
      @cto = cto
      @routes = routes
      @answerers = answerers
      @now = now
    end

    # The stored message (new or the one this client id already stored), and the
    # jobs to enqueue once the caller has it. Raises Refused for an empty or
    # over-long text, an app whose CTO has no web chat, or a file the rules in
    # Attachments refuse. `attachments`: the composer's upload tokens.
    def call(text, client_id: nil, attachments: [])
      text = text.to_s.gsub(/\r\n?/, "\n").strip
      tokens = Array(attachments).map(&:to_s).reject(&:blank?)
      raise Refused.new("Write a message first.", code: "EMPTY") if text.empty? && tokens.empty?
      raise Refused.new("Keep it under #{MAX_LENGTH} characters.", code: "TOO_LONG") if text.length > MAX_LENGTH
      raise Refused.new("This CTO has no web chat yet.", code: "NO_WEB_CHAT") unless self.class.available?(@cto, routes: @routes)

      external_id = "#{@user.id}:#{client_id.to_s.match?(CLIENT_ID) ? client_id : SecureRandom.uuid}"
      thread_key = WebChat.thread_key(@cto.app_slug, @user.id)
      existing = AgentMessage.find_by(channel: "web", external_id: external_id)
      return existing if existing&.thread_key == thread_key

      external_id = "#{@user.id}:#{SecureRandom.uuid}" if existing
      blobs = Attachments.resolve!(tokens, app_slug: @cto.app_slug, user: @user)
      person = self.class.person_for(@user)
      attrs = { channel: "web", external_id: external_id, guild_id: nil, channel_ref: @cto.app_slug,
                thread_key: thread_key, author_ref: @user.id.to_s, author_name: @user.display_name.to_s[0, 200],
                person: person, content: text, mentions: {}, sent_at: @now,
                envelope: { "via" => "web_chat", "app" => @cto.app_slug, "user_id" => @user.id,
                            "attachments" => (blobs.size if blobs.any?) }.compact }

      return store(attrs, person, blobs) unless blobs.empty?

      confirm(text, attrs, person) || store(attrs, person, name_answer: name_answer(text, attrs))
    rescue ActiveRecord::RecordNotUnique
      AgentMessage.find_by!(channel: "web", external_id: external_id)
    end

    # Whether `cto` has a web chat: the `web:` block lists its soul.
    def self.available?(cto, routes: Routes.current) = cto.present? && routes.web_soul?(cto.soul)

    # The person a web message from `user` would be from, read without making
    # one: nil until their first message (see THE PERSON above).
    def self.existing_person(user)
      return nil unless user

      AgentPersonIdentity.find_by(platform: "web", external_id: user.id.to_s)&.person || AgentPerson.find_by(user_id: user.id)
    end

    # The person a web message from `user` is from. See THE PERSON above.
    def self.person_for(user, attempt: 1)
      external_id = user.id.to_s
      identity = AgentPersonIdentity.find_by(platform: "web", external_id: external_id)
      return identity.person if identity

      name = user.display_name.to_s[0, 100]
      AgentPerson.transaction(requires_new: true) do
        person = AgentPerson.find_by(user_id: user.id) || AgentPerson.create!(display_name: name, user: user)
        person.identities.create!(platform: "web", external_id: external_id, display_name: name)
        person
      end
    rescue ActiveRecord::RecordNotUnique
      raise if attempt > 1

      person_for(user, attempt: attempt + 1)
    end

    private

    # The owner's answer to the CTO's first-name ask (FirstNameAsk), or nil.
    def name_answer(text, attrs)
      FirstNameAsk.answer_for(@user, attrs[:thread_key], text)
    end

    # `name_answer`: a FirstNameAsk::Answer, answered in code (no model, no
    # tokens) when the message is not held, ahead of the cap.
    def store(attrs, person, blobs = [], name_answer: nil)
      capped = AgentMessage.transaction(requires_new: true) do
        limited = rate_limited?(attrs[:thread_key])
        # The probe carries no person: built with one, it would join the
        # person's unsaved `messages` and fail their next save.
        probe = AgentMessage.new(attrs.except(:person).merge(soul_slug: @cto.soul))
        owner_only = !@answerers.role_answered?(person) && @answerers.app_owner_thread?(probe, person)
        held = limited || !@answerers.allowed?(person, message: probe)
        message = AgentMessage.create!(attrs.merge(soul_slug: @cto.soul, routed_by: "chat",
                                                   status: held ? "held" : "received"))
        message.record!("received", actor: "web-chat", detail: { "author" => message.author_name, "user_id" => @user.id })
        attach(message, blobs)
        message.record!("routed", actor: "router", detail: { "matched" => "the #{@cto.app_slug} CTO chat",
                                                             "soul" => @cto.soul, "routed_by" => "chat" })
        if limited
          message.record!("rate_limited", actor: "board",
                                          detail: { "limit" => RATE_LIMIT, "window_minutes" => (RATE_WINDOW / 60).to_i })
        end
        message.record!("held", actor: "answerers", detail: { "reason" => @answerers.held_reason(person), "person_id" => person&.id }.compact) if held && !limited
        if name_answer && !held
          message.code_answered!(FirstNameAsk.reply!(@user, name_answer), summary: FirstNameAsk::SUMMARY,
                                 meta: { "first_name" => name_answer.skip? ? "skipped" : "saved" }, now: @now)
          next [ message, true ]
        end
        meter = owner_only && !held ? owner_meter : nil
        message.usage_capped!(meter, now: @now) if meter&.capped?
        [ message, meter&.capped? ]
      end
      message, answered = capped
      AgentMessageReplyJob.perform_later(message.id) if answered
      message
    end

    # The app's owner meter (AgentUsage.owner_meter), or nil with no App row.
    def owner_meter
      app = App.find_by(slug: @cto.app_slug)
      app && AgentUsage.owner_meter(app, now: @now, answerers: @answerers)
    end

    # The owner's word on a proposal in this thread (ProposalConfirm), or nil.
    def confirm(text, attrs, person)
      intent = ProposalConfirm.intent(text)
      return nil unless intent

      proposal = AgentProposal.for_word(thread_key: attrs[:thread_key], channel: "web", guild_id: nil,
                                        channel_ref: attrs[:channel_ref])
      return nil unless proposal

      message, jobs = AgentMessage.transaction(requires_new: true) do
        ProposalConfirm.new(proposal: proposal, intent: intent, now: @now).store!(attrs, person: person, source: "web-chat")
      end
      jobs.each { |job, id| job.perform_later(id) }
      message
    end

    # The files, on the message, before the dispatcher can claim it (same
    # transaction). Recorded by kind and size, never by content.
    def attach(message, blobs)
      return if blobs.empty?

      message.attachments.attach(blobs)
      message.record!("attached", actor: "web-chat",
                                  detail: { "files" => blobs.size, "bytes" => blobs.sum(&:byte_size),
                                            "kinds" => blobs.map { |b| Attachments.kind(b.content_type) }.tally })
    end

    def rate_limited?(thread_key)
      AgentMessage.where(channel: "web", thread_key: thread_key).where("created_at > ?", @now - RATE_WINDOW).count >= RATE_LIMIT
    end
  end
end
