module AgentMessages
  # Turns ONE email that reached team@ through the Resend inbound into an
  # AgentMessage (channel `email`) when it is for a CTO, after the desk has
  # captured it (docs/agents/system/agent-message-loop.md, "Email"). Everything
  # else returns nil and stays a plain desk capture, exactly as before.
  #
  # Called by DeskCaptureResendIngestJob only. The Gmail read
  # (Gmail::MailboxIngest) never comes here: agents never read alex@'s mailbox.
  #
  # IN ORDER:
  #   1. Loop guards (EmailLoopGuard): our own mail, a CTO to a CTO, auto replies,
  #      lists, bounces. Guarded mail is not stored at all.
  #   2. Trust (EmailTrust): only the topmost amazonses.com verdict, with aligned
  #      DKIM and DMARC, names the sender. A verified sender resolves to a person
  #      by the `email` identity (AgentPerson.resolve!); Alex McRitchie's alex@mcritchie.studio
  #      is the owner's. An unverified one has NO person, so it is the public,
  #      held, and never claimable, whatever its From line says.
  #   3. Thread: a reply whose In-Reply-To or References names an email the
  #      mailbox holds joins that row's thread (and channel_ref); otherwise the
  #      thread is keyed `email:<root Message-ID>` (the first References id, else
  #      In-Reply-To, else its own Message-ID).
  #   4. The owner's go / no / change: in a thread with a proposal is handled in
  #      code first (ProposalConfirm, as on Discord).
  #   5. Routing (EmailRoutes): a CTO alias, else a CTO named in a mail to team@,
  #      else the thread's soul. Not routed: nil.
  #   6. Rate limit: past RATE_LIMIT messages from verified senders in one thread
  #      within RATE_WINDOW the row is stored `held` with a `rate_limited` event,
  #      never answered. Unverified rows never count toward it.
  #   7. The owner-only guard (Answerers), as on Discord: an unanswered role is held.
  #
  # Idempotent on (channel, external_id), the Message-ID.
  class EmailIngest
    RATE_LIMIT = 10
    RATE_WINDOW = 1.hour
    REFERENCES_KEPT = 20

    def initialize(routes: EmailRoutes.current, answerers: Answerers.current, logger: Rails.logger, now: Time.current)
      @routes = routes
      @guard = EmailLoopGuard.new(routes: routes)
      @answerers = answerers
      @logger = logger
      @now = now
    end

    def call(raw, desk_item: nil, source: "resend-inbound")
      mail = Mail.read_from_string(raw.to_s)
      message_id = clean_id(mail.message_id)
      return skip("no Message-ID") if message_id.nil?

      existing = AgentMessage.find_by(channel: "email", external_id: message_id)
      return existing if existing

      headers = EmailTrust.headers(raw)
      trust = EmailTrust.verdict(raw)
      from = trust.from_addr
      if (why = @guard.reason(headers, from: from))
        return skip("#{message_id}: #{why}")
      end

      text = EmailBody.new_text(desk_item&.body_text.presence || DeskCapture::Parser.extract_body(mail))
      subject = mail.subject.to_s.strip[0, 300]
      in_reply_to = Array(mail.in_reply_to).map { |id| clean_id(id) }.compact.first
      references = Array(mail.references).map { |id| clean_id(id) }.compact.last(REFERENCES_KEPT)
      parent = parent_row([ in_reply_to, *references ].compact)

      envelope = {
        "from" => from, "from_name" => from_name(mail), "to" => addresses(mail.to), "cc" => addresses(mail.cc),
        "subject" => subject, "message_id" => message_id, "in_reply_to" => in_reply_to, "references" => references,
        "trust" => trust.to_h, "desk_item_id" => desk_item&.id
      }.compact
      result = @routes.route(to: mail.to, cc: mail.cc, subject: subject, text: text)
      result = EmailRoutes::Result.new(soul: parent.soul_slug, routed_by: "thread",
                                       detail: { "matched" => "reply to message #{parent.id}" }) if !result.routed? && parent&.soul_slug.present?
      soul = result.soul
      thread_key = parent&.thread_key || "email:#{references.first || in_reply_to || message_id}"
      channel_ref = parent&.channel_ref || @routes.address_for(soul) || @routes.team_address || "email"

      person = trust.verified? ? AgentPerson.resolve!(platform: "email", external_id: from, display_name: from_name(mail)) : nil
      attrs = { channel: "email", external_id: message_id, guild_id: nil, channel_ref: channel_ref,
                thread_key: thread_key, author_ref: person ? from : nil,
                author_name: person ? from_name(mail) : "#{from || 'unknown sender'} (unverified)"[0, 200],
                person: person, content: content(subject, text), mentions: {}, envelope: envelope,
                sent_at: mail.date&.to_time || @now }

      confirmed = confirm(text, attrs, person, in_reply_to, source)
      return confirmed if confirmed
      return skip("#{message_id}: #{result.detail['reason']}") unless result.routed?

      store(attrs, result, person, trust, source)
    rescue ActiveRecord::RecordNotUnique
      AgentMessage.find_by(channel: "email", external_id: message_id)
    end

    private

    def store(attrs, result, person, trust, source)
      AgentMessage.transaction(requires_new: true) do
        limited = rate_limited?(attrs[:thread_key])
        held = limited || !@answerers.allowed?(person)
        message = AgentMessage.create!(attrs.merge(soul_slug: result.soul, routed_by: result.routed_by,
                                                   status: held ? "held" : "received"))
        message.record!("received", actor: source, detail: { "author" => message.author_name, "trust" => trust.to_h })
        message.record!("routed", actor: "router",
                                  detail: result.detail.merge("soul" => result.soul, "routed_by" => result.routed_by))
        if limited
          message.record!("rate_limited", actor: "board",
                                          detail: { "limit" => RATE_LIMIT, "window_minutes" => (RATE_WINDOW / 60).to_i })
        end
        if held
          reason = trust.verified? ? @answerers.held_reason(person) : "sender not verified (#{trust.reason}); treated as the public"
          message.record!("held", actor: "answerers", detail: { "reason" => reason, "person_id" => person&.id }.compact)
        end
        message
      end
    end

    # The owner's word on a proposal in this thread (ProposalConfirm), or nil.
    def confirm(text, attrs, person, in_reply_to, source)
      intent = ProposalConfirm.intent(text)
      return nil unless intent

      proposal = AgentProposal.for_word(thread_key: attrs[:thread_key], channel: "email", guild_id: nil,
                                        channel_ref: attrs[:channel_ref], reference_id: in_reply_to)
      return nil unless proposal

      message, jobs = AgentMessage.transaction(requires_new: true) do
        ProposalConfirm.new(proposal: proposal, intent: intent, now: @now).store!(attrs, person: person, source: source)
      end
      jobs.each { |job, id| job.perform_later(id) }
      message
    end

    # Only rows from VERIFIED senders count, so a stranger (or a forger) cannot
    # fill a thread and hold the owner's next message.
    def rate_limited?(thread_key)
      AgentMessage.where(channel: "email", thread_key: thread_key).where("created_at > ?", @now - RATE_WINDOW)
                  .where("agent_messages.envelope -> 'trust' ->> 'verified' = 'true'")
                  .count >= RATE_LIMIT
    end

    # The newest email row this mail replies to: one whose Message-ID it names.
    def parent_row(ids)
      return nil if ids.empty?

      AgentMessage.where(channel: "email", external_id: ids).order(id: :desc).first
    end

    def content(subject, text)
      [ ("Subject: #{subject}" if subject.present?), text.presence ].compact.join("\n\n").presence || "(empty email)"
    end

    def from_name(mail)
      name = mail[:from]&.addrs&.first&.display_name.to_s.strip
      name.presence || mail.from&.first.to_s
    rescue StandardError
      mail.from&.first.to_s
    end

    def addresses(list) = Array(list).map { |a| a.to_s.strip.downcase }.first(20)

    def clean_id(id)
      value = id.to_s.strip.delete_prefix("<").delete_suffix(">").strip
      value.empty? ? nil : value[0, 300]
    end

    def skip(why)
      @logger.info("[agent-messages] email not for an agent: #{why}")
      nil
    end
  end
end
