module AgentMessages
  # The memory one answer is given: the context bundle for a claimed message,
  # rebuilt from the hub's rows on every answer, so every dispatcher on every
  # machine sees the same context for the same rows. A warm domain's owner and
  # team turns also resume the domain's Claude session, but still read this
  # bundle per message for the audience, rules and thread.
  # docs/agents/system/agent-message-loop.md, "Memory" and "Warm sessions".
  #
  # THE PERSON LAYER is one person's exchanges with one soul on EVERY channel and
  # platform: every earlier row with the same (soul_slug, person_id), oldest first,
  # each labeled with the place it happened (`[discord #release-notes]`). What
  # Alex McRitchie told Alex in one channel, Alex knows in the next. Another person's messages
  # are never in it.
  #
  # THE THREAD LAYER is the focus: the conversation this message continues, every
  # earlier row of its thread_key (a Discord reply chain, a Discord thread
  # channel, later an email thread), whoever wrote it, because the reply chose it.
  # A terse follow-up ("what's next?") resolves inside it first. It comes only from
  # THIS channel and guild: DiscordIngest inherits the thread_key of any referenced
  # row, and a Discord forward references a message elsewhere, whose audience is
  # not this one. A thread row is never repeated in the PERSON layer.
  #
  # PRUNING (the PERSON layer). The last VERBATIM_TURNS turns no older than
  # VERBATIM_WINDOW (measured from the message's own sent time, not the clock, so a
  # rebuild is identical) come back verbatim. Every older turn folds into the
  # SUMMARY: an EXTRACTIVE summary, one line per turn (its date and place, the
  # first line of the message and of the answer, each cut to SUMMARY_SIDE), the
  # newest SUMMARY_LINES kept. Extractive on purpose: a pure function of the rows,
  # no model call, and no model-written text that could carry an injected
  # instruction forward. The THREAD layer keeps its newest THREAD_TURNS.
  #
  # THE USER LAYER is the person's notes (AgentPersonNote), on every channel,
  # each with its date, source message and that message's place. The notes are
  # per PERSON, and who shares them turns on the sender's role NOW
  # (AgentPersonNote.visible_for): an owner's or team member's notes are shared
  # by every soul in every domain; a client's or the public's are read only by
  # souls of the domain that filed them (config/agent_domains.yml `souls:`). A
  # fact said twice in two domains is shown once. The PERSON layer, by contrast,
  # is per person PER SOUL.
  #
  # THE AUDIENCE is who the soul is speaking with (agent-communication SOP): the
  # role of the message's person, resolved here on the board and never from the
  # message text. No person is public. The worker gates the action and the
  # internal layers on it (AgentMailbox::Audience).
  #
  # A CLIENT CTO (soul `client_cto`, docs/agents/system/client-cto.md) is one soul
  # for every client app, so its PERSON layer is cut to THIS app's rows
  # (channel_ref): an owner of two client apps never hears one app's CTO recall
  # the other's chat. Its bundle also carries `persona`, the app's AppCto row
  # (AppCto#persona_json), which the worker fills its persona template from,
  # inside the untrusted fence. Every other soul's bundle has `persona: nil`.
  # And its audience: a sender the board knows only as `public` who OWNS the app
  # (an AppMembership owner, a server-side fact, never the message's) is that
  # app's client, scoped to it (`client_domain` the app slug, underscored), so
  # the CTO may talk about their own project.
  #
  # AN APP OWNER on their own app's CTO thread (Answerers#app_owner_thread?,
  # any CTO, ours or a client's) is answered there, and is that app's client
  # (Answerers#audience_for): never higher, so no read action, no internal
  # context, only the domain's notes, and the proposal catalog a client sees.
  # The audience is the same one the notes, the catalog and the proposal check
  # (AgentProposal.record_from!) read, so no layer answers a higher role than
  # the rules the worker prints.
  #
  # THE GOOGLE LAYER (`google_context`) is a small read-only snapshot of the
  # sender's OWN Google (GoogleConnect::OwnerContext: calendar, newest mail
  # headers, the Drive files they picked, or a legacy row's newest), present only when the sender is the OWNER of
  # what this soul answers for (#google_context?), and nil for everyone else.
  # Two owners, both server-side facts, never the message's:
  #   - a client CTO's app owner on that app's own CTO thread
  #     (Answerers#app_owner_thread?: web channel, the thread key built for
  #     that user, the app's CTO soul, an owner AppMembership), answered as
  #     that app's client: THEIR OWN connections only;
  #   - on any hub soul (every soul but client_cto), a sender answered as the
  #     owner audience whose person holds the owner role AND whose hub user is
  #     an admin, on a PRIVATE channel only (#private_channel?: the web chat,
  #     verified email, a Discord DM; never a guild channel members read): the
  #     household's connections (GoogleConnection.household, the set
  #     /admin/google reads).
  # FAIL CLOSED: no person, no hub user, a /build or satellite chat thread, a public, team or
  # client sender, another app's owner, a mismatched audience, or any error
  # while deciding all mean no google_context. Its text (subjects, snippets,
  # titles, file names) is written by strangers, so the worker prints it
  # inside the untrusted fence as data, and a message carrying it is answered
  # cold, never in a warm session (AgentMailbox::WarmSession.eligible?).
  #
  # `ledger` and `user.notes` (a string) repeat the pre-omnichannel shape for a
  # worker still running the older ContextBuilder; drop them once every
  # dispatcher runs this release.
  class MemoryBundle
    VERBATIM_TURNS = 10
    VERBATIM_WINDOW = 7.days
    # Rows read per layer; the person and thread indexes bound each scan.
    FETCH_LIMIT = 200
    THREAD_TURNS = 20
    # Rows no layer shows: unrouted (no soul was asked) and held (a sender the
    # owner-only guard does not answer, AgentMessages::Answerers), so a
    # stranger's words never reach an answer's context.
    UNSEEN_STATUSES = %w[unrouted held].freeze
    SUMMARY_LINES = 40
    SUMMARY_SIDE = 140

    def initialize(message)
      @message = message
    end

    def as_of = @message.sent_at || @message.created_at

    def bundle
      thread = thread_rows
      in_thread = thread.map(&:id).to_set
      fetched = person_rows
      rows = fetched.reject { |row| in_thread.include?(row.id) }
      recent, older = split(rows)
      total = person_scope.count
      @notes = visible_notes
      @places = places(thread + rows + [ @message ] + @notes.filter_map(&:source_message))
      thread_total = thread_scope.count
      person_turns = recent.map { |row| turn(row) }
      thread_turns = thread.map { |row| turn(row) }
      summary = summary(older)
      {
        "message_id" => @message.id,
        "as_of" => as_of.iso8601,
        "place" => place(@message),
        "audience" => audience,
        "person" => {
          "id" => @message.person_id, "display_name" => person&.display_name, "soul" => @message.soul_slug,
          "total" => total, "unread" => [ total - fetched.size, 0 ].max, "in_thread" => fetched.size - rows.size,
          "turns" => person_turns, "summary" => summary
        },
        "thread" => {
          "key" => @message.thread_key, "place" => place(@message), "continues" => thread.any?,
          "total" => thread_total, "omitted" => [ thread_total - thread.size, 0 ].max, "turns" => thread_turns
        },
        "user" => user_json,
        "proposals" => proposals_json,
        "persona" => persona_json,
        "google_context" => google_context_json,
        "ledger" => { "turns" => person_turns, "summary" => summary, "pin" => thread_turns.last }
      }.merge(intake_json).merge(attachments_json)
    end

    # The audience this message is answered as ({"role", "client_domain"}). See
    # THE AUDIENCE above. Public: AgentProposal.record_from! checks a proposal
    # against the same audience the catalog offered.
    def audience = @audience ||= audience_json

    private

    def person = @message.person

    # Whose role the answer is held to. A /build thread is read by whoever holds
    # the request's token (BuildIntake), so every turn there is answered as the
    # public, whoever sent it: no read action, internal context or owner notes.
    # A satellite chat thread (AgentChat) likewise: its person is whoever an
    # app's ONE bearer credential names by email, so the hub cannot know who
    # reads the answer, and an owner's email over the API is the public too.
    def audience_person = public_thread? ? nil : person

    # Whether this thread is answered as the public whoever sent it: /build and
    # the satellite chat.
    def public_thread? = BuildIntake.thread?(@message.thread_key) || AgentChat.thread?(@message.thread_key)

    # A /build thread's intake state (BuildIntake::Context): what Alex asks next.
    # No key at all on any other thread.
    def intake_json
      return {} unless BuildIntake.thread?(@message.thread_key)

      intake = BuildIntake::Context.for(@message)
      intake ? { "intake" => intake } : {}
    end

    # THE FILES the message carries (web chat: images and PDFs), each with a URL
    # that expires (AgentMessages::Attachments.for_worker), so the holder can read
    # them; absent when there are none. Only this message's own files: a cold run
    # sends the newest message's media, and older ones stay in the warm session.
    def attachments_json
      return {} unless @message.attachments.attached?

      { "attachments" => Attachments.for_worker(@message) }
    end

    # The notes this soul may read about this sender (AgentPersonNote.visible_for,
    # by the role the board resolves now), oldest first, one per fact. A note
    # stored under an older filter is held to today's here (admissible?), so a
    # bracketed or machinery-shaped one already on a row never reaches a prompt.
    def visible_notes
      return [] unless person

      role = audience["role"]
      notes = AgentPersonNote.visible_for(person, soul: @message.soul_slug, role: role)
                             .includes(:source_message).order(:noted_at, :id).to_a
                             .select { |note| AgentPersonNote.admissible?(note.body) }.uniq(&:fingerprint)
      # A satellite chat reads only what was learned in satellite chats, as its
      # person layer does (#person_scope): a note from the person's Discord, email
      # or hub chat is not shown to whoever an app's credential names by email.
      return notes unless AgentChat.thread?(@message.thread_key)

      notes.select { |note| AgentChat.thread?(note.source_message&.thread_key) }
    end

    # What this soul may propose to THIS sender (config/agent_domains.yml through
    # AgentMailbox::DomainRegistry, filtered by the sender's audience, which the
    # board resolves from the person's role), and the thread's newest proposal,
    # so a `change: …` is answered with the offer it changes in view. A soul
    # that is no domain's front door gets an empty catalog. `last` carries, from
    # code, whether it was offered to this sender (`own`) and on which message
    # (`source_message_id`): a warm turn takes it only from a shown own turn
    # (AgentMailbox::WarmSession.eligible?).
    def proposals_json
      audience = AgentMailbox::Audience.new(role: self.audience["role"], client_domain: self.audience["client_domain"])
      last = AgentProposal.in_thread(@message).where("agent_proposals.created_at <= ?", @message.created_at)
                          .order(id: :desc).first
      { "catalog" => AgentProposal.registry.catalog(@message.soul_slug, audience: audience),
        "last" => last && last.as_context_json.merge(
          "own" => last.person_id.present? && last.person_id == @message.person_id,
          "source_message_id" => last.source_message_id
        ) }
    end

    def person_scope
      return AgentMessage.none if @message.person_id.blank? || @message.soul_slug.blank?

      scope = AgentMessage.where(soul_slug: @message.soul_slug, person_id: @message.person_id)
                          .where("agent_messages.id < ?", @message.id)
                          .where.not(status: UNSEEN_STATUSES)
      # A satellite chat's person layer reads only the person's satellite chats:
      # their Discord, email and hub-chat history with this soul is not shown to
      # whoever an app's credential names by email.
      if AgentChat.thread?(@message.thread_key)
        prefix = AgentChat::THREAD_PREFIX
        scope = scope.where("left(agent_messages.thread_key, ?) = ?", prefix.length, prefix)
      end
      client_cto? ? scope.where(channel_ref: @message.channel_ref) : scope
    end

    def client_cto? = @message.soul_slug == AppCto::SOUL

    def audience_json
      base = audience_person ? Answerers.current.audience_for(@message, audience_person) : AgentPerson.audience_for(nil)
      return base unless client_cto? && base["role"] == "public" && app_owner?

      base.merge("role" => "client", "client_domain" => @message.channel_ref.to_s.tr("-", "_"))
    end

    def app_owner?
      user = person&.user
      user&.slug.present? && AppMembership.owners.exists?(app_slug: @message.channel_ref, user_slug: user.slug)
    end

    # The owner's Google snapshot, or nil. See THE GOOGLE LAYER above.
    def google_context_json
      reader = google_reader
      reader&.snapshot
    rescue StandardError => e
      Rails.logger.warn("[memory_bundle] google_context skipped: #{e.class}")
      nil
    end

    # Which owner's Google this message may read (a GoogleConnect::OwnerContext),
    # or nil. Every branch must hold; anything unexpected is nil.
    def google_reader
      return nil unless audience_person && person

      user = person.user
      return nil unless user&.persisted?

      if client_cto?
        return nil unless audience == { "role" => "client", "client_domain" => @message.channel_ref.to_s.tr("-", "_") }
        return nil unless Answerers.current.app_owner_thread?(@message, person)

        GoogleConnect::OwnerContext.for_user(user)
      elsif audience["role"] == "owner" && person.role == "owner" && user.admin? && private_channel?
        GoogleConnect::OwnerContext.household
      end
    end

    # Whether only the sender reads this conversation, so the household's
    # calendar, mail snippets and file names (one-time codes among them) may be
    # answered in it: the hub's web chat, an email whose sender passed DKIM and
    # DMARC (EmailTrust, stamped in the envelope at ingest), or a Discord DM (no
    # guild; the gateway drops DMs today, so none arrives). A guild channel,
    # which every member reads, never is.
    def private_channel?
      case @message.channel.to_s
      # A satellite chat (AgentChat) is never private: the hub cannot know who
      # reads it.
      when "web" then @message.guild_id.blank? && !AgentChat.thread?(@message.thread_key)
      when "email" then (@message.envelope || {}).dig("trust", "verified") == true
      when "discord" then @message.guild_id.blank?
      # A Slack DM to the app (channel_type im, stamped at ingest): only the
      # sender and the app read it.
      when "slack" then (@message.envelope || {})["channel_type"] == "im"
      # A Teams personal chat with the bot (conversationType personal, stamped
      # at ingest): only the sender and the bot read it.
      when "teams" then (@message.envelope || {})["conversation_type"] == "personal"
      else false
      end
    end

    # The client CTO's persona for this app, or nil (every other soul, or a
    # client app whose row is gone: the worker then answers as a plain CTO).
    def persona_json
      return nil unless client_cto?

      AppCto.includes(:app).find_by(app_slug: @message.channel_ref)&.persona_json
    end

    # Oldest first, the newest FETCH_LIMIT.
    def person_rows
      person_scope.order(created_at: :desc, id: :desc).limit(FETCH_LIMIT).with_attached_attachments.to_a.reverse
    end

    # A fan's siblings (AgentMessage::FAN_KEY: the same Slack message stored for
    # another soul) are left out: their text IS this message, and whether a
    # sibling has answered yet is a race, so the thread layer would differ run
    # to run.
    def thread_scope
      scope = AgentMessage.where(thread_key: @message.thread_key, channel: @message.channel,
                                 channel_ref: @message.channel_ref, guild_id: @message.guild_id)
                          .where("agent_messages.id < ?", @message.id)
                          .where.not(status: UNSEEN_STATUSES)
      fan = @message.envelope.to_h[AgentMessage::FAN_KEY].presence
      fan ? scope.where("agent_messages.envelope->>'fan' IS DISTINCT FROM ?", fan) : scope
    end

    # Oldest first, the newest THREAD_TURNS.
    def thread_rows
      thread_scope.order(id: :desc).limit(THREAD_TURNS).with_attached_attachments.to_a.reverse
    end

    def user_json
      return nil unless person

      facts = @notes.map do |note|
        note.as_api_json.merge("place" => note.source_message ? place(note.source_message) : nil)
      end
      { "person_id" => person.id, "display_name" => person.display_name,
        "facts" => facts, "notes" => @notes.map(&:body).join("\n") }
    end

    def split(rows)
      floor = as_of - VERBATIM_WINDOW
      fresh_from = [ rows.size - VERBATIM_TURNS, 0 ].max
      recent = rows.each_with_index.select { |row, i| i >= fresh_from && sent(row) >= floor }.map(&:first)
      [ recent, rows - recent ]
    end

    # `turns` counts the older turns this bundle read; `omitted` the ones past
    # SUMMARY_LINES; the layer's `total` minus what was read is older still.
    def summary(older)
      kept = older.last(SUMMARY_LINES)
      { "turns" => older.size, "omitted" => older.size - kept.size, "lines" => kept.map { |row| summary_line(row) } }
    end

    def summary_line(row)
      asked = first_line(row.content)
      answered = row.response_text.present? ? first_line(row.response_text) : "(no answer)"
      "#{sent(row).to_date.iso8601} #{place(row)} asked: #{asked} | answered: #{answered}"
    end

    def first_line(text)
      line = text.to_s.strip.lines.first.to_s.strip
      line.length > SUMMARY_SIDE ? "#{line[0, SUMMARY_SIDE - 1]}…" : line
    end

    def turn(row)
      { "id" => row.id, "at" => sent(row).iso8601, "place" => place(row), "author_name" => row.author_name,
        "author_ref" => row.author_ref, "own" => row.person_id.present? && row.person_id == @message.person_id,
        "content" => row.content.to_s, "answer" => row.response_text, "status" => row.status }
        .merge(row.attachments.any? ? { "files" => row.attachments.map { |a| a.blob.filename.to_s } } : {})
    end

    # The place label, CODE-SHAPED on purpose: it is printed outside the prompt's
    # untrusted fence, so it never carries text a member chose. A channel's name
    # (set by the guild's admins) is kept to [a-z0-9_-]; a thread is named by its
    # parent channel, since anyone may name a thread.
    def place(row)
      key = [ row.guild_id.to_s, row.channel_ref.to_s ]
      name = (@places || {})[key]
      return slack_place(row) if row.channel == "slack"
      return teams_place(row) if row.channel == "teams"
      return "[#{row.channel}]" unless row.channel == "discord"
      return "[discord channel #{row.channel_ref.to_s.gsub(/\D/, '')[0, 25]}]" unless name

      "[discord #{name}]"
    end

    # A Slack row's place: the channel's name from config/agent_routes.yml (code,
    # never a name a member chose), a DM, else the channel id.
    def slack_place(row)
      return "[slack dm]" if (row.envelope || {})["channel_type"] == "im"

      name = AgentMessages::SlackRoutes.current.channel_name(row.channel_ref).to_s.gsub(/[^a-z0-9_-]/, "")[0, 40]
      name.present? ? "[slack ##{name}]" : "[slack channel #{row.channel_ref.to_s.gsub(/[^A-Za-z0-9]/, '')[0, 25].downcase}]"
    end

    # A Teams row's place: the channel's name from config/agent_routes.yml
    # teams.channels (code, never a name a member chose), a personal chat,
    # else a neutral label (a Teams conversation id is long and opaque).
    def teams_place(row)
      return "[teams chat]" if (row.envelope || {})["conversation_type"] == "personal"

      name = AgentMessages::TeamsRoutes.current.channel_name(row.channel_ref).to_s.gsub(/[^a-z0-9_-]/, "")[0, 40]
      name.present? ? "[teams ##{name}]" : "[teams channel]"
    end

    # { [guild, channel] => "#name" | "thread in #parent" } for every channel the
    # rows name, in two queries at most (the channel directory, DiscordChannel).
    def places(rows)
      keys = rows.select { |row| row.channel == "discord" }.map { |row| [ row.guild_id.to_s, row.channel_ref.to_s ] }.uniq
      return {} if keys.empty?

      found = directory(keys)
      parents = directory(found.values.select { |c| c.kind == "thread" && c.parent_external_id.present? }
                                .map { |c| [ c.guild_external_id, c.parent_external_id ] }.uniq)
      found.each_with_object({}) do |(key, channel), out|
        if channel.kind == "thread"
          parent = parents[[ channel.guild_external_id, channel.parent_external_id ]]
          out[key] = parent ? "thread in ##{safe_name(parent.name)}" : "thread"
        else
          out[key] = "##{safe_name(channel.name)}"
        end
      end
    end

    def directory(keys)
      return {} if keys.empty?

      scope = keys.map { |guild, id| DiscordChannel.where(guild_external_id: guild, external_id: id) }.reduce(:or)
      scope.to_a.index_by { |c| [ c.guild_external_id, c.external_id ] }
    end

    def safe_name(name) = name.to_s.downcase.gsub(/[^a-z0-9_-]+/, "-").gsub(/-{2,}/, "-").delete_prefix("-")
                              .delete_suffix("-")[0, 50].presence || "channel"

    def sent(row) = row.sent_at || row.created_at
  end
end
