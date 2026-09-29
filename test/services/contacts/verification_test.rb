require "test_helper"
require "rake"

# [integration] Contacts::Verification and `contacts:verify` over real contact
# rows, against a fake ZeroBounce that stands in for the bulk API: who is
# picked and in what order, how each result lands on the contact, the credit
# guard, idempotency (a verified contact is never resubmitted), and resuming a
# submitted file.
class Contacts::VerificationTest < ActiveSupport::TestCase
  # Stands in for Contacts::ZeroBounce above the HTTP layer; answers each
  # submitted address with the status `verdicts` names (valid otherwise).
  class FakeZeroBounce
    attr_reader :submitted, :polls
    attr_accessor :balance

    def initialize(balance: 10_000, verdicts: {}, polls_until_complete: 1)
      @balance = balance
      @verdicts = verdicts
      @polls_until_complete = polls_until_complete
      @submitted = []
      @polls = 0
    end

    def credits = @balance

    def send_file(emails)
      @submitted << emails
      @balance -= emails.size
      "file-#{@submitted.size}"
    end

    def file_status(_file_id)
      @polls += 1
      { "file_status" => @polls > @polls_until_complete ? "Complete" : "Processing", "complete_percentage" => "50%" }
    end

    def complete?(status) = status["file_status"] == "Complete"

    def results(_file_id)
      @submitted.last.to_a.map do |email|
        status, sub = Array(@verdicts.fetch(email, "valid"))
        Contacts::ZeroBounce::Result.new(email: email, status: status, sub_status: sub)
      end
    end
  end

  setup do
    @broadcast = Broadcast.create!(slug: "cyvasse-is-back", subject: "Hi", template_key: "cyvasse_is_back", target_list: "cyvasse-legacy")
    @recent  = legacy("recent@example.com")
    @middle  = legacy("middle@example.com")
    @old     = legacy("old@example.com")
    @unknown = legacy("unranked@example.com")
    @recency = { "recent@example.com" => 1.day.ago, "middle@example.com" => 1.year.ago, "old@example.com" => 8.years.ago }
    @sent = legacy("sent@example.com")
    @broadcast.deliveries.create!(contact: @sent, sent_at: 1.hour.ago)
    @gone = legacy("gone@example.com").tap(&:unsubscribe!)
    @other = Contact.create!(email: "turf@example.com", tags: [ "turf" ])
    @done = legacy("done@example.com")
    @done.record_verification!(status: "valid")
  end

  def legacy(email) = Contact.create!(email: email, tags: [ "cyvasse-legacy" ])

  def verification(client, limit: 10, **opts)
    Contacts::Verification.new(client: client, limit: limit, broadcast: @broadcast, recency: @recency,
                               sleeper: ->(_s) { }, out: StringIO.new, **opts)
  end

  test "picks unverified subscribed list contacts never sent, most recently active first" do
    picked = verification(FakeZeroBounce.new).pick.map(&:last)
    assert_equal %w[recent@example.com middle@example.com old@example.com unranked@example.com], picked
  end

  test "the limit takes the most recent" do
    assert_equal %w[recent@example.com middle@example.com], verification(FakeZeroBounce.new, limit: 2).pick.map(&:last)
  end

  test "a run stores every result and unsubscribes the undeliverable" do
    zb = FakeZeroBounce.new(verdicts: { "middle@example.com" => %w[invalid mailbox_not_found],
                                        "old@example.com" => "catch-all", "unranked@example.com" => "spamtrap" })
    summary = verification(zb).run

    assert_equal 1, zb.submitted.size, "one bulk file"
    assert_equal({ "valid" => 1, "invalid" => 1, "catch-all" => 1, "spamtrap" => 1 }, summary.counts)
    assert_equal 2, summary.unsubscribed
    assert_equal 10_000, summary.credits_before
    assert_equal 9_996, summary.credits_after

    assert_equal [ "valid", true, nil ], state(@recent)
    assert_equal [ "invalid", false, "verification" ], state(@middle)
    assert_equal "mailbox_not_found", @middle.verification_sub_status
    assert_equal [ "catch-all", true, nil ], state(@old), "catch-all stays subscribed"
    assert_equal [ "spamtrap", false, "verification" ], state(@unknown)
    assert_not_nil @recent.verified_at
  end

  test "a second run submits nothing: verified contacts are never resubmitted" do
    zb = FakeZeroBounce.new
    verification(zb).run
    second = verification(zb).run

    assert_equal 1, zb.submitted.size
    assert_equal 0, second.picked
    assert_nil second.file_id
  end

  test "refuses to submit when the balance is too low, and writes nothing" do
    zb = FakeZeroBounce.new(balance: 3)
    error = assert_raises(Contacts::ZeroBounce::Error) { verification(zb).run }
    assert_match "only 3 credits", error.message
    assert_empty zb.submitted
    assert_equal 1, Contact.verified.count, "only the fixture verified in setup"
  end

  test "a dry run picks and reads the balance but submits and writes nothing" do
    zb = FakeZeroBounce.new
    summary = verification(zb, dry_run: true).run

    assert_equal 4, summary.picked
    assert_equal 3, summary.ranked
    assert_equal 10_000, summary.credits_before
    assert_empty zb.submitted
    assert_equal 1, Contact.verified.count
  end

  test "polls until the file completes" do
    zb = FakeZeroBounce.new(polls_until_complete: 3)
    verification(zb).run
    assert_equal 4, zb.polls
  end

  test "resuming a file id submits nothing and leaves stored verdicts alone" do
    zb = FakeZeroBounce.new
    zb.submitted << [ "recent@example.com", "done@example.com" ]
    summary = verification(zb, file_id: "file-1").run

    assert_equal 1, zb.submitted.size, "no new file"
    assert_equal({ "valid" => 1, "already_verified" => 1 }, summary.counts)
    assert_equal "valid", @recent.reload.verification_status
  end

  test "the resume line is flushed the moment the file is submitted" do
    out = Class.new(StringIO) { attr_reader :flushed; def flush = (@flushed = string.dup) }.new
    verification(FakeZeroBounce.new, limit: 1, out: out).run
    assert_match "submitted 1 as file file-1 (resume with FILE_ID=file-1)", out.flushed
  end

  test "a status ZeroBounce adds later is stored as unknown, keeping the raw value" do
    zb = FakeZeroBounce.new(verdicts: { "recent@example.com" => "shiny_new" })
    verification(zb, limit: 1).run
    assert_equal "unknown", @recent.reload.verification_status
    assert_equal "unrecognized:shiny_new", @recent.verification_sub_status
    assert @recent.subscribed?
  end

  test "read_recency parses email,last_active_at, skipping headers and junk, keeping the latest" do
    csv = "email,last_active_at\nA@Example.com,2019-05-01T00:00:00Z\na@example.com,2021-01-01T00:00:00Z\nnot-an-email,2020-01-01\nb@example.com,garbage\n"
    map = Contacts::Verification.read_recency(StringIO.new(csv))
    assert_equal [ "a@example.com" ], map.keys
    assert_equal Time.utc(2021, 1, 1), map["a@example.com"]
  end

  test "contacts:verify DRY_RUN=1 reports the pick and changes nothing" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("contacts:verify")
    file = Tempfile.new([ "recency", ".csv" ])
    file.write("email,last_active_at\nrecent@example.com,2026-09-01T00:00:00Z\n")
    file.close
    ENV["DRY_RUN"] = "1"
    saved_key = ENV.delete("ZEROBOUNCE_API_KEY")
    task = Rake::Task["contacts:verify"]
    task.reenable
    out = capture_io { task.invoke("2", file.path) }.first

    assert_match "DRY RUN: cyvasse-legacy minus cyvasse-is-back recipients: 4 unverified candidates, 2 picked (1 ranked by the CSV of 1)", out
    assert_match "credits: not read (no ZEROBOUNCE_API_KEY)", out
    assert_equal 1, Contact.verified.count
  ensure
    ENV.delete("DRY_RUN")
    ENV["ZEROBOUNCE_API_KEY"] = saved_key if saved_key
    file&.unlink
  end

  private

  def state(contact)
    contact.reload
    [ contact.verification_status, contact.subscribed?, contact.unsubscribe_reason ]
  end
end
