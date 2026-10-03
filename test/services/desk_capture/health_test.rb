require "test_helper"

# [unit] DeskCapture::Health — the team@ inbound check. DNS and Resend are both
# injected fakes; no test here touches the network.
class DeskCaptureHealthTest < ActiveSupport::TestCase
  NOW = Time.zone.parse("2026-10-02 12:00:00 UTC")

  FakeResolver = Struct.new(:exchanges, :error) do
    def getresources(name, type)
      raise error if error
      raise "wrong host #{name}" unless name == DeskCapture::Health::MX_HOST
      raise "wrong type #{type}" unless type == Resolv::DNS::Resource::IN::MX

      exchanges.map { |x| Resolv::DNS::Resource::IN::MX.new(10, Resolv::DNS::Name.create(x)) }
    end
  end

  FakeResend = Struct.new(:rows, :error) do
    def list_received(limit:)
      raise error if error

      rows
    end
  end

  GOOD_MX = [ "inbound-smtp.us-east-1.amazonaws.com." ].freeze

  def health(mx: GOOD_MX, rows: [], resolver_error: nil, resend_error: nil)
    DeskCapture::Health.new(resolver: FakeResolver.new(mx, resolver_error),
                            resend: FakeResend.new(rows, resend_error), now: -> { NOW })
  end

  def ingested(id)
    DeskCaptureItem.create!(s3_key: "resend/#{id}.eml", source: "resend", status: "received",
                            from_addr: "a@example.com", subject: "s", received_at: NOW - 1.hour)
  end

  def row(id, age)
    { "id" => id, "created_at" => (NOW - age).iso8601 }
  end

  test "healthy: MX routes to SES inbound and every settled Resend email is on the desk" do
    ingested("re_1")
    result = health(rows: [ row("re_1", 1.hour) ]).check

    assert result.ok?, result.message
    assert_match(/MX in.mcritchie.studio -> inbound-smtp/, result.message)
  end

  test "a missing MX record fails and says the mail is not arriving" do
    result = health(mx: []).check

    refute result.ok?
    assert_match(/no MX record/, result.failures.first)
    assert_match(/NOT arriving/, result.failures.first)
  end

  test "an MX pointing somewhere else fails and names what it found" do
    result = health(mx: [ "mx.elsewhere.example." ]).check

    refute result.ok?
    assert_match(/found: mx.elsewhere.example/, result.failures.first)
  end

  test "a DNS error fails rather than passing silently" do
    result = health(resolver_error: Resolv::ResolvError.new("timeout")).check

    refute result.ok?
    assert_match(/MX lookup .* failed: Resolv::ResolvError/, result.failures.first)
  end

  test "a settled Resend email with no DeskCaptureItem is a dropped ingest, named by id" do
    ingested("re_ok")
    result = health(rows: [ row("re_ok", 2.hours), row("re_lost", 2.hours) ]).check

    refute result.ok?
    assert_equal 1, result.failures.size
    assert_match(/dropped 1 Resend email.*re_lost/, result.failures.first)
    refute_match(/re_ok/, result.failures.first)
  end

  test "an email still inside the grace window is not yet a drop" do
    result = health(rows: [ row("re_fresh", 2.minutes) ]).check

    assert result.ok?, result.message
  end

  test "an unreadable created_at counts as settled, so a drop is never hidden" do
    result = health(rows: [ { "id" => "re_odd", "created_at" => "not a time" } ]).check

    refute result.ok?
    assert_match(/re_odd/, result.failures.first)
  end

  test "a Resend API failure fails the check rather than reading as an empty inbox" do
    result = health(resend_error: RuntimeError.new("Resend list received failed: 401")).check

    refute result.ok?
    assert_match(/could not list Resend received emails.*401/, result.failures.first)
  end
end
