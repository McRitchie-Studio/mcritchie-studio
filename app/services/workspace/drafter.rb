module Workspace
  # Writes one draft into one allow-listed mailbox, and logs it.
  #
  # The end of the pipeline is a DRAFT and a LINK. A human opens the link, reads
  # the draft, and presses Send — nothing here can, because GmailClient has no
  # send method and test/lib/no_gmail_send_test.rb bans the calls repo-wide.
  #
  # The mailbox must be a WorkspaceMailbox row that is impersonatable right now
  # (active, in an active workspace). That is checked HERE as well as inside
  # Credentials#authorizer_for, so an injected client — every test, and any
  # future caller that builds its own — cannot skip the allow-list.
  class Drafter
    Error = Class.new(StandardError)

    Result = Struct.new(:draft_id, :message_id, :thread_id, :url, :log, keyword_init: true)

    def initialize(mailbox:, drafted_by:, client: nil)
      @address = WorkspaceMailbox.normalize_address(mailbox)
      @drafted_by = drafted_by.to_s.strip
      @client = client

      raise Error, "drafted_by is required — every draft names who asked for it" if @drafted_by.empty?
    end

    # reply_query: a Gmail query naming the ONE thread to answer. When given,
    # the draft is threaded into it, addressed to its sender by default, and
    # subject-prefixed "Re:". ThreadFinder refuses a query that matches more.
    def call(subject: nil, markdown:, to: nil, cc: nil, reply_query: nil)
      mailbox = allowed_mailbox!
      reply = reply_query.present? ? ThreadFinder.new(client).reply_headers(reply_query) : nil

      message = DraftMessage.new(
        from: mailbox.address,
        to: to.presence || reply&.reply_to,
        cc: cc,
        subject: subject.presence || reply_subject(reply),
        markdown: markdown,
        signature: mailbox.signature,
        in_reply_to: reply&.message_id,
        references: reply&.references
      )

      draft = client.drafts_create(raw: message.to_mime, thread_id: reply&.thread_id)
      message_id = draft.message&.id
      log = record!(mailbox, draft, message, message_id, reply)

      Result.new(draft_id: draft.id, message_id: message_id, thread_id: log.gmail_thread_id,
                 url: GmailClient.draft_url(message_id || draft.id, mailbox: mailbox.address), log: log)
    end

    private

    # The draft ALREADY EXISTS in Gmail by the time this runs, so a failure here
    # must not read as "no draft": it is an unlogged draft. ErrorLog gets the
    # exception (best-effort — a failing ErrorLog must not hide the original),
    # and the raise names the Gmail draft id so the operator can find it.
    def record!(mailbox, draft, message, message_id, reply)
      MailboxDraft.create!(
        workspace_mailbox: mailbox,
        drafted_by: @drafted_by,
        gmail_draft_id: draft.id,
        gmail_message_id: message_id,
        gmail_thread_id: draft.message&.thread_id || reply&.thread_id,
        subject: message.subject.to_s[0, 250],
        recipients: (message.to + message.cc).join(", ")[0, 250]
      )
    rescue StandardError => e
      begin
        ErrorLog.capture!(e) if defined?(ErrorLog)
      rescue StandardError
        nil
      end
      raise Error, "draft #{draft.id} WAS created in #{mailbox.address} but its log row failed " \
                   "(#{e.class}) — the draft is in Gmail; record it by hand"
    end

    def allowed_mailbox!
      mailbox = WorkspaceMailbox.find_by(address: @address)
      raise Error, "#{@address} is not a registered mailbox — bin/rails 'workspace:add_mailbox[#{@address}]'" if mailbox.nil?
      unless WorkspaceMailbox.impersonatable?(@address)
        raise Error, "#{@address} is not draftable: mailbox #{mailbox.status}, " \
                     "workspace #{mailbox.workspace_account.status}. Prove it with " \
                     "bin/rails 'workspace:check_mailbox[#{@address}]'"
      end

      mailbox
    end

    def client
      @client ||= GmailClient.new(subject: @address)
    end

    def reply_subject(reply)
      raise Error, "a new draft needs a subject" if reply.nil?

      reply.subject.match?(/\Are:/i) ? reply.subject : "Re: #{reply.subject}"
    end
  end
end
