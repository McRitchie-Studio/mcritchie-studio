module Workspace
  # Finds the ONE thread an operator named, and reads only that thread.
  #
  # The reading rule for drafting is "only the thread you point at": the
  # operator names an email ("the Higgsfield decline from last week"), the agent
  # turns that into a narrow Gmail query, and this resolves it to exactly one
  # thread. A query that matches several threads is REFUSED rather than guessed
  # at — and refused WITHOUT opening any of them, so a loose query costs a retry,
  # never a read of mail nobody asked about.
  class ThreadFinder
    # Ids per page, and the most pages walked. The walk stops the moment a
    # SECOND thread appears, so an ambiguous query costs one page; only a query
    # that really is one long thread walks further. Ids and thread ids only —
    # no message is opened while deciding.
    PAGE_SIZE = 100
    MAX_PAGES = 10

    Error = Class.new(StandardError)
    NotFound = Class.new(Error)

    class Ambiguous < Error
      def initialize(query, detail)
        super("#{query.inspect} #{detail} — narrow it (from:, subject:, newer_than:) until it names one")
      end
    end

    # The newest message's headers, which is everything a reply needs to thread.
    Reply = Struct.new(:thread_id, :subject, :reply_to, :message_id, :references, keyword_init: true)

    def initialize(client)
      @client = client
    end

    # EVERY matching message is considered, not just the first page: a long
    # thread can fill the first page on its own and hide a second thread that
    # also matches. Deciding from a sample would draft into the wrong thread.
    def thread_id_for(query)
      threads = []
      cursor = nil
      pages = 0
      loop do
        page = @client.messages_list(query: query, cursor: cursor, limit: PAGE_SIZE)
        pages += 1
        threads |= Array(page.messages).map(&:thread_id)
        raise Ambiguous.new(query, "matched more than one thread") if threads.size > 1

        cursor = page.next_page_token.presence
        break if cursor.nil?
        raise Ambiguous.new(query, "matched over #{PAGE_SIZE * MAX_PAGES} messages") if pages >= MAX_PAGES
      end
      raise NotFound, "no message matches #{query.inspect}" if threads.empty?

      threads.first
    end

    # Headers of the newest message in the thread, for In-Reply-To/References.
    def reply_headers(query)
      thread = @client.threads_get(thread_id_for(query), format: "metadata")
      newest = Array(thread.messages).last or raise NotFound, "thread for #{query.inspect} carried no messages"
      headers = header_map(newest)

      Reply.new(
        thread_id: thread.id,
        subject: headers["subject"].to_s,
        reply_to: headers["reply-to"].presence || headers["from"],
        message_id: headers["message-id"],
        references: [ headers["references"], headers["message-id"] ].compact.join(" ").presence
      )
    end

    # The whole thread as plain text, oldest first — what the agent reads before
    # it writes the reply. Bodies come from each message's text/plain part; a
    # message with only HTML says so rather than being silently skipped.
    def transcript(query)
      render(@client.threads_get(thread_id_for(query), format: "full"))
    end

    # The transcript plus, when asked, every attachment's bytes — what
    # `bin/mail thread --save` writes to disk. Reads only; still the ONE thread.
    Attachment = Struct.new(:message_id, :filename, :mime_type, :data, keyword_init: true)

    def export(query, attachments: false)
      thread = @client.threads_get(thread_id_for(query), format: "full")
      files = attachments ? Array(thread.messages).flat_map { |m| fetch_attachments(m) } : []
      { thread_id: thread.id, transcript: render(thread), attachments: files }
    end

    private

    def render(thread)
      Array(thread.messages).map { |message|
        headers = header_map(message)
        names = attachment_parts(message.payload).map(&:filename)
        [
          "From: #{headers['from']}",
          "Date: #{headers['date']}",
          "Subject: #{headers['subject']}",
          ("Attachments: #{names.join(', ')}" if names.any?),
          "",
          plain_body(message.payload) || "(no plain-text part — HTML only)"
        ].compact.join("\n")
      }.join("\n\n#{'-' * 60}\n\n")
    end

    # Every part that names a file, at any depth.
    def attachment_parts(part)
      return [] if part.nil?

      own = part.filename.to_s.empty? ? [] : [ part ]
      own + Array(part.parts).flat_map { |child| attachment_parts(child) }
    end

    # Small attachments ride inline in `body.data`; the rest carry an
    # attachment_id and are fetched one read each.
    def fetch_attachments(message)
      attachment_parts(message.payload).map do |part|
        data = part.body&.data
        if data.nil? && part.body&.attachment_id
          data = @client.attachment_get(message.id, part.body.attachment_id).data
        end
        Attachment.new(message_id: message.id, filename: part.filename, mime_type: part.mime_type, data: data.to_s)
      end
    end

    def header_map(message)
      Array(message.payload&.headers).each_with_object({}) do |header, map|
        map[header.name.to_s.downcase] = header.value
      end
    end

    # Depth-first: multipart/alternative nests the text part a level down, and
    # a reply with an attachment nests it two. The gem has already decoded
    # base64url `data` into bytes.
    def plain_body(part)
      return nil if part.nil?
      # A text/plain ATTACHMENT (notes.txt) is a file, not the message body.
      if part.mime_type == "text/plain" && part.filename.to_s.empty?
        return part.body&.data.to_s.dup.force_encoding(Encoding::UTF_8).scrub
      end

      Array(part.parts).each do |child|
        found = plain_body(child)
        return found if found
      end
      nil
    end
  end
end
