require "test_helper"
require "google/apis/gmail_v1"

# [unit] Workspace::Drafter and ThreadFinder — the allow-list is checked even
# with an injected client, replies thread into the ONE named conversation, a
# loose query is refused before any thread is opened, and every draft is logged.
class WorkspaceDrafterTest < ActiveSupport::TestCase
  G = Google::Apis::GmailV1

  # Stands in for Workspace::GmailClient with real gem objects, and records
  # every call so the test can say what was — and was not — read.
  class FakeClient
    attr_reader :calls

    def initialize(matches: [])
      @matches = matches
      @calls = []
    end

    def messages_list(query:, limit:)
      @calls << [ :messages_list, query, limit ]
      G::ListMessagesResponse.new(messages: @matches.map { |id, thread| G::Message.new(id: id, thread_id: thread) })
    end

    def threads_get(id, format:)
      @calls << [ :threads_get, id, format ]
      headers = { "From" => "Billing <billing@vendor.test>", "Subject" => "Your payment failed",
                  "Message-ID" => "<m2@vendor.test>", "References" => "<m1@vendor.test>", "Date" => "Tue, 22 Sep 2026" }
      part = G::MessagePart.new(mime_type: "text/plain", body: G::MessagePartBody.new(data: "Card declined."))
      payload = G::MessagePart.new(mime_type: "multipart/alternative", parts: [ part ],
                                   headers: headers.map { |n, v| G::MessagePartHeader.new(name: n, value: v) })
      G::Thread.new(id: id, messages: [ G::Message.new(id: "m2", thread_id: id, payload: payload) ])
    end

    def drafts_create(raw:, thread_id: nil)
      @calls << [ :drafts_create, raw, thread_id ]
      G::Draft.new(id: "r-1", message: G::Message.new(id: "msg-9", thread_id: thread_id || "t-new"))
    end
  end

  setup do
    @account = WorkspaceAccount.create!(domain: "mason.test")
    @account.mark_verified!
    @mailbox = @account.workspace_mailboxes.create!(address: "alex@mason.test", signature: "— Alex")
    @mailbox.mark_verified!
  end

  def drafter(client) = Workspace::Drafter.new(mailbox: "alex@mason.test", drafted_by: "alex", client: client)

  test "a new draft is created, logged, and linked into the RIGHT mailbox" do
    client = FakeClient.new
    result = drafter(client).call(to: "billing@vendor.test", subject: "Card declines", markdown: "**Hi**")

    _, raw, thread = client.calls.last
    mail = Mail.new(raw)
    assert_nil thread
    assert_equal [ "alex@mason.test" ], mail.from
    assert_includes mail.html_part.decoded, "— Alex", "the mailbox signature is appended"

    log = result.log
    assert_equal [ "alex@mason.test", "alex", "r-1", "msg-9" ],
                 [ log.mailbox_address, log.drafted_by, log.gmail_draft_id, log.gmail_message_id ]
    assert_equal "https://mail.google.com/mail/u/alex@mason.test/#drafts?compose=msg-9", result.url
    assert_equal [ :drafts_create ], client.calls.map(&:first), "a new draft reads nothing"
  end

  test "a reply threads into the named conversation and answers its sender" do
    client = FakeClient.new(matches: [ [ "m1", "t-7" ], [ "m2", "t-7" ] ])
    result = drafter(client).call(markdown: "Thanks — retrying now.", reply_query: "from:vendor.test subject:payment")

    _, raw, thread = client.calls.last
    mail = Mail.new(raw)
    assert_equal "t-7", thread
    assert_equal "Re: Your payment failed", mail.subject
    assert_equal [ "billing@vendor.test" ], mail.to
    assert_equal "m2@vendor.test", mail.in_reply_to
    assert_includes mail.header["References"].to_s, "<m1@vendor.test> <m2@vendor.test>"
    assert_equal "t-7", result.log.gmail_thread_id
  end

  test "a query matching several threads is refused before ANY thread is opened" do
    client = FakeClient.new(matches: [ [ "m1", "t-1" ], [ "m2", "t-2" ] ])

    assert_raises(Workspace::ThreadFinder::Ambiguous) do
      drafter(client).call(markdown: "x", reply_query: "from:vendor.test")
    end
    assert_equal [ :messages_list ], client.calls.map(&:first), "only ids were listed; no thread was read"
    assert_equal 0, MailboxDraft.count
  end

  test "the transcript reads the one thread as plain text" do
    client = FakeClient.new(matches: [ [ "m2", "t-7" ] ])
    text = Workspace::ThreadFinder.new(client).transcript("subject:payment")

    assert_includes text, "From: Billing <billing@vendor.test>"
    assert_includes text, "Card declined."
  end

  test "the allow-list holds even with an injected client" do
    client = FakeClient.new

    @mailbox.revoke!("paused")
    assert_raises(Workspace::Drafter::Error) { drafter(client).call(to: "a@b.test", subject: "s", markdown: "x") }

    assert_raises(Workspace::Drafter::Error) do
      Workspace::Drafter.new(mailbox: "ceo@mason.test", drafted_by: "alex", client: client)
                        .call(to: "a@b.test", subject: "s", markdown: "x")
    end
    assert_empty client.calls, "a refused mailbox never reaches Gmail"
  end

  test "every draft must name who asked for it" do
    assert_raises(Workspace::Drafter::Error) { Workspace::Drafter.new(mailbox: "alex@mason.test", drafted_by: " ") }
  end
end
