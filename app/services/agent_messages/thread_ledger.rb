module AgentMessages
  # The memory one answer is given: the context bundle for a claimed message,
  # rebuilt from the hub's rows on every answer (never a resumed Claude session),
  # so every dispatcher on every machine sees the same context for the same rows.
  # docs/agents/system/agent-message-loop.md, "Memory".
  #
  # THE LEDGER is one person's exchanges with one soul in one channel: every
  # earlier row with the same (soul_slug, channel, channel_ref, author_ref), oldest
  # first. Another person's messages in the same channel are never in it.
  #
  # THE PIN. A message that replies into a held thread (its thread_key names an
  # earlier root, DiscordIngest's convention `discord:<channel>:<root id>`) pins
  # the latest earlier row of that thread: the exchange being answered. The pin is
  # always included, even when another person wrote it, and leaves the turn list.
  #
  # PRUNING. The last VERBATIM_TURNS turns no older than VERBATIM_WINDOW (measured
  # from the message's own sent time, not the clock, so a rebuild is identical)
  # come back verbatim. Every older turn folds into the SUMMARY: an EXTRACTIVE
  # summary, one line per turn (its date, the first line of the message and the
  # first line of the answer, each cut to SUMMARY_SIDE characters), the newest
  # SUMMARY_LINES kept. Extractive on purpose: it is a pure function of the rows,
  # costs no model call, and stores no model-written text that could drift or
  # carry an injected instruction forward from one answer to every later one.
  class ThreadLedger
    VERBATIM_TURNS = 10
    VERBATIM_WINDOW = 7.days
    # Rows read per bundle; the index on the ledger key bounds the scan.
    FETCH_LIMIT = 200
    SUMMARY_LINES = 40
    SUMMARY_SIDE = 140

    def initialize(message)
      @message = message
    end

    def as_of = @message.sent_at || @message.created_at

    def bundle
      pin = pinned_row
      fetched = ledger_rows
      rows = fetched.reject { |row| pin && row.id == pin.id }
      recent, older = split(rows)
      total = ledger_scope.count
      {
        "message_id" => @message.id,
        "as_of" => as_of.iso8601,
        "ledger" => {
          "soul" => @message.soul_slug, "channel" => @message.channel, "channel_ref" => @message.channel_ref,
          "author_ref" => @message.author_ref.presence, "author_name" => @message.author_name,
          "total" => total, "unread" => [ total - fetched.size, 0 ].max,
          "turns" => recent.map { |row| turn(row) },
          "summary" => summary(older),
          "pin" => pin && turn(pin)
        },
        "user" => AgentUserNote.for_author(channel: @message.channel, author_ref: @message.author_ref)&.as_api_json
      }
    end

    # The thread root a reply joined, or nil when this message started its own.
    def reply_root
      root = @message.thread_key.to_s.split(":").last.to_s
      root.empty? || root == @message.external_id ? nil : root
    end

    private

    def ledger_scope
      return AgentMessage.none if @message.author_ref.blank? || @message.soul_slug.blank?

      AgentMessage.where(soul_slug: @message.soul_slug, channel: @message.channel,
                         channel_ref: @message.channel_ref, author_ref: @message.author_ref)
                  .where("agent_messages.id < ?", @message.id)
                  .where.not(status: "unrouted")
    end

    # Oldest first, the newest FETCH_LIMIT.
    def ledger_rows
      ledger_scope.order(created_at: :desc, id: :desc).limit(FETCH_LIMIT).to_a.reverse
    end

    def pinned_row
      return nil unless reply_root

      AgentMessage.where(thread_key: @message.thread_key).where("id < ?", @message.id).order(id: :desc).first
    end

    def split(rows)
      floor = as_of - VERBATIM_WINDOW
      fresh_from = [ rows.size - VERBATIM_TURNS, 0 ].max
      recent = rows.each_with_index.select { |row, i| i >= fresh_from && sent(row) >= floor }.map(&:first)
      [ recent, rows - recent ]
    end

    # `turns` counts the older turns this bundle read; `omitted` the ones past
    # SUMMARY_LINES; the ledger's `total` minus what was read is older still.
    def summary(older)
      kept = older.last(SUMMARY_LINES)
      { "turns" => older.size, "omitted" => older.size - kept.size, "lines" => kept.map { |row| summary_line(row) } }
    end

    def summary_line(row)
      asked = first_line(row.content)
      answered = row.response_text.present? ? first_line(row.response_text) : "(no answer)"
      "#{sent(row).to_date.iso8601} asked: #{asked} | answered: #{answered}"
    end

    def first_line(text)
      line = text.to_s.strip.lines.first.to_s.strip
      line.length > SUMMARY_SIDE ? "#{line[0, SUMMARY_SIDE - 1]}…" : line
    end

    def turn(row)
      { "id" => row.id, "at" => sent(row).iso8601, "author_name" => row.author_name, "author_ref" => row.author_ref,
        "content" => row.content.to_s, "answer" => row.response_text, "status" => row.status }
    end

    def sent(row) = row.sent_at || row.created_at
  end
end
