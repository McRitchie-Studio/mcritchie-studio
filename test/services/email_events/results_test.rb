require "test_helper"

# [unit] Results credited to an email, and the ref added to links that land
# on our own sites.
class EmailEvents::ResultsTest < ActiveSupport::TestCase
  Results = EmailEvents::Results

  setup do
    broadcast = Broadcast.create!(subject: "Hi", template_key: "cyvasse_is_back")
    @delivery = broadcast.deliveries.create!(contact: Contact.create!(email: "res-#{SecureRandom.hex(3)}@example.com"))
  end

  test "each goal is credited once per email however often it is reported" do
    3.times { Results.record!(@delivery.token, "played_match") }
    Results.record!(@delivery.token, "signed_in")

    goals = @delivery.events.of_kind("converted").map { |e| e.data["goal"] }
    assert_equal %w[played_match signed_in], goals.sort
    assert(@delivery.events.of_kind("converted").all? { |e| e.source == "beacon" })
  end

  test "an unknown goal or token records nothing" do
    Results.record!(@delivery.token, "bought_a_yacht")
    Results.record!("not-a-token", "signed_in")
    Results.record!(nil, "signed_in")
    assert_equal 0, EmailEvent.count
  end

  test "the ref is added only to links on our own sites" do
    assert_equal "https://cyvasse.xyz/play?ref=tok", Results.with_ref("https://cyvasse.xyz/play", "tok")
    assert_equal "https://cyvasse.mcritchie.studio/play?ref=tok", Results.with_ref("https://cyvasse.mcritchie.studio/play", "tok"),
                 "the old Cyvasse host stays ours: emails already sent link to it"
    assert_equal "https://mcritchie.studio/build?a=1&ref=tok", Results.with_ref("https://mcritchie.studio/build?a=1&ref=old", "tok")
    assert_equal "https://example.com/tt", Results.with_ref("https://example.com/tt", "tok")
    assert_equal "https://evilmcritchie.studio/x", Results.with_ref("https://evilmcritchie.studio/x", "tok")
  end

  # task first-game-feedback-survey: the survey reads its token as ?t=.
  test "a hub survey link carries the token as t, every other hub page as ref" do
    assert_equal "https://mcritchie.studio/s/cyvasse-first-game?t=tok",
                 Results.with_ref("https://mcritchie.studio/s/cyvasse-first-game", "tok")
    assert_equal "https://www.mcritchie.studio/s/x?t=tok", Results.with_ref("https://www.mcritchie.studio/s/x?t=old", "tok")
    assert_equal "https://mcritchie.studio/s/x/thanks?ref=tok", Results.with_ref("https://mcritchie.studio/s/x/thanks", "tok")
    assert_equal "https://cyvasse.xyz/s/x?ref=tok", Results.with_ref("https://cyvasse.xyz/s/x", "tok"),
                 "only the hub's own /s/ is a survey"
  end

  test "a customer app on a mcritchie.studio subdomain never receives the token" do
    assert_equal "https://someones-app.mcritchie.studio/", Results.with_ref("https://someones-app.mcritchie.studio/", "tok")
    assert_equal "https://cyvasse.mcritchie.studio./play?ref=tok", Results.with_ref("https://cyvasse.mcritchie.studio./play", "tok")
  end

  test "a result that cannot be recorded is logged and never raises" do
    BroadcastDelivery.stub(:find_by, ->(*) { raise ActiveRecord::ConnectionTimeoutError, "pool" }) do
      assert_difference -> { ErrorLog.count }, 1 do
        assert_nil Results.record!(@delivery.token, "signed_in")
      end
    end
  end

  test "a failed credit is logged with its goal and email even when ErrorLog is down too" do
    logged = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(logged)
    BroadcastDelivery.stub(:find_by, ->(*) { raise ActiveRecord::ConnectionNotEstablished, "db down" }) do
      ErrorLog.stub(:capture!, ->(*) { raise ActiveRecord::ConnectionNotEstablished, "db down" }) do
        assert_nil Results.record!(@delivery.token, "played_match")
      end
    end
    assert_match(/played_match for #{Regexp.escape(@delivery.token.first(8))}/, logged.string)
  ensure
    Rails.logger = original
  end
end
