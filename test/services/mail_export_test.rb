require "test_helper"
require "google/apis/gmail_v1"

# [unit] MailExport — the dyno half of bin/mail. Every verb is a read; the
# thread verb goes through ThreadFinder with a fake Gmail client that records
# its calls, so the test can say what was fetched (and that nothing drafted).
class MailExportTest < ActiveSupport::TestCase
  G = Google::Apis::GmailV1

  class FakeGmail
    attr_reader :calls

    def initialize = @calls = []

    def messages_list(query:, limit:, cursor: nil)
      @calls << [ :messages_list, query ]
      G::ListMessagesResponse.new(messages: [ G::Message.new(id: "m1", thread_id: "t-1") ])
    end

    def threads_get(id, format:)
      @calls << [ :threads_get, id, format ]
      header = ->(n, v) { G::MessagePartHeader.new(name: n, value: v) }
      body = G::MessagePart.new(mime_type: "text/plain", body: G::MessagePartBody.new(data: "See attached."))
      notes = G::MessagePart.new(mime_type: "text/plain", filename: "notes.txt",
                                 body: G::MessagePartBody.new(data: "inline notes"))
      pdf = G::MessagePart.new(mime_type: "application/pdf", filename: "Term Sheet.pdf",
                               body: G::MessagePartBody.new(attachment_id: "att-9"))
      payload = G::MessagePart.new(mime_type: "multipart/mixed", parts: [ body, notes, pdf ],
                                   headers: [ header.("From", "a@example.com"), header.("Subject", "Terms") ])
      G::Thread.new(id: id, messages: [ G::Message.new(id: "m1", thread_id: id, payload: payload) ])
    end

    def attachment_get(message_id, attachment_id)
      @calls << [ :attachment_get, message_id, attachment_id ]
      G::MessagePartBody.new(data: "%PDF-1.7")
    end
  end

  setup do
    account = WorkspaceAccount.create!(domain: "example.com")
    account.mark_verified!
    account.workspace_mailboxes.create!(address: "ops@example.com").mark_verified!
  end

  def thread_request(files:, mailbox: "ops@example.com")
    { "verb" => "thread", "query" => "from:a@example.com subject:Terms", "mailbox" => mailbox, "files" => files }
  end

  test "thread without files returns the transcript, lists attachment names, and fetches no bytes" do
    gmail = FakeGmail.new
    answer = MailExport.call(thread_request(files: false), gmail: gmail)

    assert_equal "t-1", answer["thread_id"]
    assert_match(/Attachments: notes.txt, Term Sheet.pdf/, answer["transcript"])
    assert_match(/See attached\./, answer["transcript"])
    refute_match(/inline notes/, answer["transcript"], "a text/plain ATTACHMENT is not the body")
    assert_empty answer["files"]
    refute gmail.calls.any? { |c| c.first == :attachment_get }
  end

  test "thread with files returns inline and fetched attachments as base64" do
    gmail = FakeGmail.new
    answer = MailExport.call(thread_request(files: true), gmail: gmail)

    files = answer["files"].to_h { |f| [ f["name"], Base64.strict_decode64(f["base64"]) ] }
    assert_equal({ "0-notes.txt" => "inline notes", "1-term-sheet.pdf" => "%PDF-1.7" }, files)
    assert_includes gmail.calls, [ :attachment_get, "m1", "att-9" ]
    assert_equal %i[messages_list threads_get attachment_get], gmail.calls.map(&:first),
                 "reads only — no draft call"
  end

  test "thread refuses a mailbox that is not allow-listed and active" do
    answer = MailExport.call(thread_request(files: false, mailbox: "stranger@example.org"), gmail: FakeGmail.new)

    assert_match(/not an active mailbox/, answer["error"])
  end

  test "desk_item routes to the reader with the files flag" do
    reader = Minitest::Mock.new
    reader.expect(:item, { "id" => 7 }, [ 7 ], files: true)

    assert_equal({ "item" => { "id" => 7 } },
                 MailExport.call({ "verb" => "desk_item", "id" => 7, "files" => true }, reader: reader))
    reader.verify
  end

  test "doctor reports the health result" do
    result = DeskCapture::Health::Result.new(failures: [ "MX gone" ], notes: [])
    health = Struct.new(:result) { def check = result }.new(result)

    assert_equal({ "ok" => false, "failures" => [ "MX gone" ], "notes" => [] },
                 MailExport.call({ "verb" => "doctor" }, health: health))
  end

  test "an unknown verb and a bad id answer with an error, never a crash" do
    assert_match(/unknown verb/, MailExport.call({ "verb" => "send" })["error"])
    assert MailExport.call({ "verb" => "desk_item", "id" => "x" })["error"]
  end
end
