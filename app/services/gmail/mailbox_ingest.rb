module Gmail
  # Pulls matching mail from ONE Gmail mailbox into the EXISTING desk queue and
  # keeps it current. The sixth mouth of the knowledge-capture funnel; it writes
  # DeskCaptureItem rows exactly like the team@ webhook leg does, so the intake
  # protocol and /admin/desk need no special case.
  #
  # Shape of the output: one raw .eml per message in the private desk bucket,
  # one DeskCaptureItem per .eml, idempotent on s3_key. Re-running after a crash
  # converges.
  #
  # THREE PROPERTIES THIS FILE EXISTS TO HOLD
  #
  # 1. It never writes to Gmail. No send, no reply, no label, no archive, no
  #    delete — and no ability to, because Gmail::Client offers none (its whole
  #    grant is one readonly scope). Position is tracked in OUR database.
  #
  # 2. Only matching messages are ever fetched. The query goes into
  #    messages.list as `q`, so a non-matching message's body never enters this
  #    process, let alone the bucket. There is no post-filter to get wrong.
  #
  # 3. A blank query REFUSES rather than defaulting to the whole mailbox. The
  #    failure mode of a missing config must be "pulled nothing", never "pulled
  #    everything".
  class MailboxIngest
    # The mailbox to read. An explicit constant rather than "whoever the
    # credential belongs to" so the operator output and the SOP can both name it.
    MAILBOX = "alex@mcritchie.studio".freeze

    # How far back the first run — and any run recovering an expired cursor —
    # reaches. Bounds the backfill so a fresh install does not walk years of
    # mail on its first pull.
    DEFAULT_BACKFILL_DAYS = 90

    Result = Struct.new(:matched, :ingested, :skipped, :quarantined, :mailbox, :mode, :error,
                        keyword_init: true) do
      def ok?
        error.nil?
      end
    end

    # client and storage are injected for the same reason Slack::ChannelIngest
    # injects its client: the suite must exercise the cursor, the fallback and
    # the copy rule without reaching Google or S3, and rescuing a real AWS or
    # HTTP error would hide the very bug the test is for.
    def initialize(client: nil, storage: DeskCapture, credentials: Credentials, clock: -> { Time.current })
      @client = client
      @storage = storage
      @credentials = credentials
      @clock = clock
    end

    def call
      # Injected client FIRST. The other order runs a real `op read` before it
      # looks at the double, so every test process would spend shared 1Password
      # quota (the scar Slack::ChannelIngest carries the same guard for).
      return skipped("no Gmail credential configured") unless @client || @credentials.configured?

      query = self.class.query
      return skipped("GMAIL_CAPTURE_QUERY is unset — refusing to read the whole mailbox") if query.blank?

      ids, mode = discover(query)
      ingest_all(ids, mode)
    rescue Client::CredentialRevoked, Credentials::Malformed => e
      # Never a quiet "nothing new" — these two are the failures that would
      # otherwise leave the funnel looking idle for weeks.
      Result.new(matched: 0, ingested: 0, skipped: 0, quarantined: 0,
                 mailbox: MAILBOX, mode: "failed", error: e.message)
    rescue StandardError => e
      Result.new(matched: 0, ingested: 0, skipped: 0, quarantined: 0,
                 mailbox: MAILBOX, mode: "failed", error: "#{e.class}: #{e.message}")
    end

    # The deal cast lives in Heroku config, NOT in this repo: mcritchie-studio
    # is public, and a committed sender list would put third-party names in git
    # forever. A config value also means widening the cast is an operator edit
    # rather than a deploy.
    def self.query
      ENV["GMAIL_CAPTURE_QUERY"].to_s.strip
    end

    def self.backfill_days
      days = ENV["GMAIL_CAPTURE_BACKFILL_DAYS"].to_i
      days.positive? ? days : DEFAULT_BACKFILL_DAYS
    end

    private

    def skipped(reason)
      Result.new(matched: 0, ingested: 0, skipped: 0, quarantined: 0,
                 mailbox: MAILBOX, mode: "skipped: #{reason}", error: nil)
    end

    def client
      @client ||= Client.new(credentials: @credentials)
    end

    # Two ways in, and the incremental one degrades into the other rather than
    # leaving a gap. An expired cursor is EXPECTED eventually — Gmail keeps
    # history for a limited window — so the fallback is a normal path, not an
    # error path.
    def discover(query)
      cursor = DeskCaptureItem.gmail_cursor

      if cursor
        begin
          return [ incremental_ids(cursor, query), "incremental from #{cursor}" ]
        rescue Client::CursorExpired
          return [ backfill_ids(query), "full sync (cursor #{cursor} expired)" ]
        end
      end

      [ backfill_ids(query), "full sync (no cursor yet)" ]
    end

    # history.list reports EVERY change, including messages the query does not
    # want, so its ids are intersected with a query-scoped list rather than
    # trusted. That keeps property 2 true on this path too: an id history
    # offered but the query does not match is never fetched.
    def incremental_ids(cursor, query)
      # Started AT the cursor, not after it: history.list includes the change
      # the cursor names, so the last message we recorded is re-reported. That
      # is deliberate — the s3_key check absorbs it, and erring toward a
      # re-read is how this never steps over a delivery that landed mid-pull.
      changed = client.paged(:history_list, "history", start_history_id: cursor)
                      .flat_map { |record| Array(record["messagesAdded"]) }
                      .filter_map { |added| added.dig("message", "id") }
                      .uniq
      return [] if changed.empty?

      changed & backfill_ids(query)
    end

    def backfill_ids(query)
      client.paged(:messages_list, "messages", query: bounded(query))
            .filter_map { |message| message["id"] }
            .uniq
    end

    # Gmail's own `after:` operator, so the bound is applied server-side with
    # everything else.
    def bounded(query)
      since = (@clock.call.utc.to_date - self.class.backfill_days).strftime("%Y/%m/%d")
      "#{query} after:#{since}"
    end

    def ingest_all(ids, mode)
      matched = ids.size
      ingested = 0
      skipped = 0
      quarantined = 0

      ids.each do |id|
        key = "#{DeskCapture::GMAIL_PREFIX}#{id}.eml"
        if DeskCaptureItem.exists?(s3_key: key)
          skipped += 1
          next
        end

        item = ingest_one(id, key)
        ingested += 1
        quarantined += 1 if item&.quarantined?
      end

      Result.new(matched: matched, ingested: ingested, skipped: skipped,
                 quarantined: quarantined, mailbox: MAILBOX, mode: mode, error: nil)
    end

    # Store the raw BEFORE the row. The bucket copy is the durable artifact; a
    # row without its .eml would point at nothing, while an .eml without its row
    # is repaired by the next run (which finds no row and re-ingests).
    # Each message carries its own historyId in the SAME response as its bytes,
    # so one request yields both. Recording it per item — rather than one
    # high-water mark per run — is what keeps the cursor from stepping over a
    # message whose row failed to write.
    def ingest_one(id, key)
      body = client.message(id)
      raw = Client.decode_raw(body, id: id)

      @storage.store(key, raw, content_type: "message/rfc822")
      @storage.ingest_raw(raw: raw, s3_key: key, source: "gmail",
                          history_id: body["historyId"].presence&.to_i)
    end
  end
end
