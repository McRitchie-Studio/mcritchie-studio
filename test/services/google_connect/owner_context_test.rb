require "test_helper"
require "support/google_connect_fakes"

# [unit] GoogleConnect::OwnerContext: one owner's own read-only Google
# snapshot for the agent answering them. A section per connected ability,
# capped; a revoked or unreadable connection is a reconnect note, never an
# exception; no token ever reaches the output; another user's rows are never
# read; a brief per-owner cache that a disconnect does not mask. Google is a
# stand-in throughout.
class GoogleConnect::OwnerContextTest < ActiveSupport::TestCase
  include GoogleConnectFakes

  ALL = "openid email #{CALENDAR} #{GMAIL} #{DRIVE}".freeze
  NOW = Time.utc(2026, 10, 27, 12)

  setup do
    @owner = users(:viewer)
    @stranger = User.create!(email: "stranger@example.com", name: "Stranger", role: "viewer")
  end

  teardown { reset_google_connect }

  # Reads under another app's keys, so every stored token is unreadable.
  def with_other_encryption_key(&)
    other = ActiveRecord::Encryption::DerivedSecretKeyProvider.new("another-synthetic-primary-key-987654321")
    ActiveRecord::Encryption.with_encryption_context(key_provider: other, &)
  end

  def fresh_token = google_answers(200, { access_token: "ya29.SECRET-ACCESS" })

  def messages(count)
    (1..count).to_h do |i|
      [ "#{GoogleConnect::GmailReader::MESSAGES_URL}/m#{i}",
        [ 200, { id: "m#{i}", internalDate: "1792000000000", snippet: "Hi &amp; hello #{i}",
                 payload: { headers: [ { name: "Subject", value: "Subject #{i}" }, { name: "From", value: "Sender #{i} <s@example.com>" } ] } } ] ]
    end
  end

  def all_routes(events: 2, mails: 2, files: 2)
    {
      GoogleConnect::CalendarReader::EVENTS_URL => [ 200, { items: (1..events).map do |i|
        { id: "e#{i}", summary: "Event #{i}", start: { dateTime: "2026-10-28T15:00:00Z" }, end: { dateTime: "2026-10-28T16:00:00Z" },
          attendees: [ {}, {} ] }
      end } ],
      **messages(mails),
      GoogleConnect::GmailReader::MESSAGES_URL => [ 200, { resultSizeEstimate: mails, messages: (1..mails).map { { id: "m#{_1}" } } } ],
      GoogleConnect::DriveReader::FILES_URL => [ 200, { files: (1..files).map do |i|
        { id: "f#{i}", name: "File #{i}", mimeType: "application/vnd.google-apps.document", modifiedTime: "2026-10-26T15:00:00Z" }
      end } ]
    }
  end

  def snapshot(user = @owner, cache: ActiveSupport::Cache::NullStore.new)
    GoogleConnect::OwnerContext.for_user(user, now: NOW, cache:).snapshot
  end

  test "[unit] a user with no connection has no snapshot and nothing is read" do
    with_connect_env do
      google_reads({})
      assert_nil snapshot
      assert_empty read_requests
    end
  end

  test "[unit] each section appears only for an ability the user connected" do
    with_connect_env do
      store_google(email: "owner@example.com", scope: "openid email #{CALENDAR}", user: @owner)
      fresh_token
      google_reads(all_routes)

      snap = snapshot

      assert_equal %w[accounts as_of calendar], snap.keys.sort
      assert_equal [ "Event 1", "Event 2" ], snap["calendar"]["events"].map { _1["title"] }
      assert_equal({ "title" => "Event 1", "start" => "2026-10-28T15:00:00Z", "end" => "2026-10-28T16:00:00Z",
                     "all_day" => false, "attendees" => 2 }, snap["calendar"]["events"].first)
      assert read_requests.all? { _1[0].start_with?(GoogleConnect::CalendarReader::EVENTS_URL) }, "no Gmail or Drive read"
      query = Rack::Utils.parse_query(URI(read_requests.first[0]).query)
      assert_equal "2026-10-27T12:00:00Z", query["timeMin"]
      assert_equal "2026-11-03T12:00:00Z", query["timeMax"], "the next 7 days"
    end
  end

  test "[unit] every section is capped: 20 events, 10 mails with snippet and no body, 10 files; long text is cut" do
    with_connect_env do
      store_google(email: "owner@example.com", scope: ALL, user: @owner)
      fresh_token
      routes = all_routes(events: 30, mails: 12, files: 15)
      routes[GoogleConnect::CalendarReader::EVENTS_URL][1][:items].first[:summary] = "x" * 1000
      google_reads(routes)

      snap = snapshot

      assert_equal 20, snap["calendar"]["events"].size
      assert_equal 10, snap["gmail"]["messages"].size
      assert_equal 10, snap["drive"]["files"].size
      assert_operator snap["calendar"]["events"].first["title"].length, :<=, GoogleConnect::OwnerContext::TEXT
      mail = snap["gmail"]["messages"].first
      assert_equal %w[date from snippet subject], mail.keys.sort, "headers and snippet, never a body"
      assert_equal "Hi & hello 1", mail["snippet"]
      assert_equal({ "name" => "File 1", "type" => "document", "modified" => "2026-10-26T15:00:00Z" }, snap["drive"]["files"].first)
      list = read_requests.map(&:first).find { _1.start_with?("#{GoogleConnect::GmailReader::MESSAGES_URL}?") }
      assert_equal "10", Rack::Utils.parse_query(URI(list).query)["maxResults"]
      assert_operator snap.to_json.length, :<, 12_000, "the whole snapshot stays small"
    end
  end

  test "[unit] a revoked connection is a reconnect note, never an exception, and no token leaves the service" do
    with_connect_env do
      store_google(email: "owner@example.com", scope: ALL, user: @owner, refresh_token: "1//REFRESH-SECRET")
      google_answers(400, { error: "invalid_grant" })
      google_reads(all_routes)

      snap = assert_difference -> { ErrorLog.count }, 3 do
        snapshot
      end

      %w[calendar gmail drive].each do |ability|
        assert_equal({ "note" => GoogleConnect::OwnerContext::RECONNECT }, snap[ability])
      end
      assert_match "/integrations", GoogleConnect::OwnerContext::RECONNECT
      refute_match(/REFRESH-SECRET|SECRET-ACCESS|1\/\/|ya29/, snap.to_json)
      refute_match(/REFRESH-SECRET|SECRET-ACCESS|1\/\/|ya29/, ErrorLog.pluck(:message, :inspect).flatten.join(" "))
    end
  end

  test "[unit] a failing read is a plain note, logged by class only, and the token is in neither" do
    with_connect_env do
      store_google(email: "owner@example.com", scope: "openid email #{GMAIL}", user: @owner)
      fresh_token
      google_reads(GoogleConnect::GmailReader::MESSAGES_URL => [ 500, { error: { message: "token ya29.SECRET-ACCESS rejected" } } ])
      log = StringIO.new
      original = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(log)

      snap = snapshot

      assert_equal({ "note" => GoogleConnect::OwnerContext::UNAVAILABLE }, snap["gmail"])
      assert_match "gmail read failed: GoogleConnect::OAuthClient::Error", log.string
      assert_equal "user:#{@owner.id} gmail: GoogleConnect::OAuthClient::Error: Gmail answered 500: token [redacted] rejected",
                   ErrorLog.last.message, "the operator sees Google's words, a token-shaped echo redacted"
      refute_match(/SECRET|ya29/, ErrorLog.pluck(:message, :inspect).flatten.join(" "))
      refute_match(/SECRET|ya29/, log.string + snap.to_json)
    ensure
      Rails.logger = original
    end
  end

  test "[unit] a connection this app can no longer decrypt is a reconnect note" do
    with_connect_env do
      conn = store_google(email: "owner@example.com", scope: "openid email #{DRIVE}", user: @owner)
      google_reads(all_routes)

      with_other_encryption_key do
        refute GoogleConnection.find(conn.id).readable?
        assert_difference -> { ErrorLog.count }, 1 do
          assert_equal({ "note" => GoogleConnect::OwnerContext::RECONNECT }, snapshot["drive"])
        end
      end
      assert_match "cannot be decrypted", ErrorLog.last.message
      assert_empty read_requests
    end
  end

  test "[unit] another user's connection is never read: for_user is the user's own rows, household the admins'" do
    with_connect_env do
      store_google(email: "stranger@example.com", scope: ALL, user: @stranger)
      store_google(email: "alex@mcritchie.studio", scope: "openid email #{CALENDAR}", user: users(:alex))
      fresh_token
      google_reads(all_routes)

      assert_nil snapshot(@owner), "the owner has no rows, so nothing, never someone else's"
      assert_empty read_requests

      household = GoogleConnect::OwnerContext.household(now: NOW, cache: ActiveSupport::Cache::NullStore.new).snapshot
      assert_equal 1, household["accounts"], "the admin's row only, never the viewer's"
      assert_equal %w[accounts as_of calendar], household.keys.sort, "the stranger's Gmail and Drive grant is not the household's"
    end
  end

  test "[unit] a snapshot is cached briefly per owner; a disconnect or dropped ability is a new key" do
    with_connect_env do
      cache = ActiveSupport::Cache::MemoryStore.new
      conn = store_google(email: "owner@example.com", scope: ALL, user: @owner)
      fresh_token
      google_reads(all_routes)

      first = snapshot(cache:)
      reads = read_requests.size
      assert_equal first, snapshot(cache:)
      assert_equal reads, read_requests.size, "the second message reads the cache, not Google"

      travel_to(Time.current + 1.second) { conn.drop!(:gmail) }
      refute snapshot(cache:).key?("gmail"), "a dropped ability shows on the next message"

      GoogleConnection.where(id: conn.id).delete_all
      assert_nil snapshot(cache:), "a disconnect shows on the next message"

      key = GoogleConnect::OwnerContext.for_user(@owner, cache:).cache_key
      refute_includes key, "1//", "the key names no token"
      assert_equal 5.minutes, GoogleConnect::OwnerContext::TTL
    end
  end

  test "[unit] a build has one deadline for every Google call: a slow section and the ones after it are short notes" do
    with_connect_env do
      store_google(email: "owner@example.com", scope: ALL, user: @owner)
      fresh_token
      routes = all_routes
      GoogleConnect::Reader.http = lambda do |url, token|
        read_requests << [ url, token ]
        sleep 5 if url.start_with?(GoogleConnect::CalendarReader::EVENTS_URL)
        status, body = routes.find { |prefix, _| url.start_with?(prefix) }.last
        [ status, JSON.generate(body) ]
      end

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      snap = GoogleConnect::OwnerContext.for_user(@owner, now: NOW, cache: ActiveSupport::Cache::NullStore.new, budget: 0.3).snapshot
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_operator elapsed, :<, 2.0, "the build stops at its budget, not at Google's pace"
      %w[calendar gmail drive].each do |ability|
        assert_equal({ "note" => GoogleConnect::OwnerContext::OUT_OF_TIME }, snap[ability], ability)
      end
      assert_equal 6.0, GoogleConnect::OwnerContext::BUDGET
    end
  end

  test "[unit] a snapshot with a could-not-read note is cached for a minute, a complete one for five" do
    with_connect_env do
      store_google(email: "owner@example.com", scope: "openid email #{GMAIL}", user: @owner)
      fresh_token
      google_reads(GoogleConnect::GmailReader::MESSAGES_URL => [ 500, { error: { message: "backend error" } } ])
      cache = ActiveSupport::Cache::MemoryStore.new

      travel_to(NOW) do
        assert_equal GoogleConnect::OwnerContext::UNAVAILABLE, snapshot(cache:)["gmail"]["note"]
        calls = read_requests.size
        travel 50.seconds
        snapshot(cache:)
        assert_equal calls, read_requests.size, "still cached inside the minute"
        travel 20.seconds
        snapshot(cache:)
        assert_operator read_requests.size, :>, calls, "a degraded snapshot is rebuilt after DEGRADED_TTL"
      end
    end
  end
end
