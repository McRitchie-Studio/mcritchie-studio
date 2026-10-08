require "test_helper"

# [unit] TiktokConnection: the TikTok account the hub drafts to, as the sign-in
# stores it. Every token here is synthetic.
class TiktokConnectionTest < ActiveSupport::TestCase
  TOKEN = "rft.synthetic-refresh-token-0001".freeze
  NOW = Time.utc(2026, 10, 8, 12, 0, 0)

  def grant(**over)
    { "access_token" => "act.synthetic", "refresh_token" => TOKEN, "open_id" => "open-synthetic-1",
      "scope" => "user.info.basic,video.upload", "expires_in" => 86_400, "refresh_expires_in" => 31_536_000 }
      .merge(over.transform_keys(&:to_s))
  end

  def raw_token(connection)
    TiktokConnection.connection.select_value("SELECT refresh_token FROM tiktok_connections WHERE id = #{connection.id}")
  end

  test "[unit] the refresh token is ciphertext at rest and reads back in the clear" do
    connection = TiktokConnection.store!(grant, by: "alex", now: NOW)

    stored = raw_token(connection)
    assert stored.present?
    assert_not_includes stored, TOKEN
    assert_not_includes stored, "synthetic-refresh"
    assert_equal TOKEN, connection.reload.refresh_token
  end

  test "[unit] an inspect masks the refresh token" do
    connection = TiktokConnection.store!(grant, by: "alex", now: NOW)

    assert_not_includes connection.inspect, TOKEN
    assert_includes connection.inspect, "open-synthetic-1" # the control: inspect does print this row
  end

  test "[unit] store! records the account, the scope, who connected it and when the token dies" do
    connection = TiktokConnection.store!(grant, by: "alex", now: NOW)

    assert_equal "open-synthetic-1", connection.open_id
    assert_equal "user.info.basic,video.upload", connection.scope
    assert_equal "alex", connection.connected_by
    assert_equal NOW, connection.connected_at
    assert_equal NOW + 31_536_000, connection.refresh_expires_at
    assert_nil connection.refreshed_at
    assert_nil connection.display_name
    assert_equal "open-synthetic-1", connection.account
  end

  test "[unit] connecting the same open id again updates its row" do
    first = TiktokConnection.store!(grant, by: "alex", now: NOW)
    first.update!(refreshed_at: NOW + 1.hour)

    assert_no_difference -> { TiktokConnection.count } do
      TiktokConnection.store!(grant(refresh_token: "rft.synthetic-second", scope: "user.info.basic"), by: "viewer", now: NOW + 1.day)
    end

    first.reload
    assert_equal "rft.synthetic-second", first.refresh_token
    assert_equal "user.info.basic", first.scope
    assert_equal "viewer", first.connected_by
    assert_equal NOW + 1.day, first.connected_at
    assert_nil first.refreshed_at, "a new sign-in is not a refresh"
  end

  test "[unit] the database holds one row per open id" do
    TiktokConnection.store!(grant, by: "alex", now: NOW)
    twin = TiktokConnection.new(open_id: "open-synthetic-1", refresh_token: "rft.other", connected_at: NOW)

    assert_not twin.valid?
    assert_raises(ActiveRecord::RecordNotUnique) { twin.save!(validate: false) }
  end

  test "[unit] current is the most recently connected account" do
    assert_nil TiktokConnection.current

    older = TiktokConnection.store!(grant(open_id: "open-older"), by: "alex", now: NOW)
    newer = TiktokConnection.store!(grant(open_id: "open-newer"), by: "alex", now: NOW + 1.hour)
    assert_equal newer, TiktokConnection.current

    TiktokConnection.store!(grant(open_id: "open-older"), by: "alex", now: NOW + 2.hours)
    assert_equal older, TiktokConnection.current, "signing the older account in again makes it current"
  end

  test "[unit] an answer without a refresh token or an open id is refused, and the message holds no value" do
    error = assert_raises(ActiveRecord::RecordInvalid) { TiktokConnection.store!(grant(refresh_token: nil), by: "alex") }
    assert_match(/Refresh token can't be blank/, error.message)

    error = assert_raises(ActiveRecord::RecordInvalid) { TiktokConnection.store!(grant(open_id: ""), by: "alex") }
    assert_match(/Open can't be blank/, error.message)
    assert_not_includes error.message, TOKEN
    assert_equal 0, TiktokConnection.count
  end

  test "[unit] no expiry is stored when TikTok names none" do
    assert_nil TiktokConnection.store!(grant(refresh_expires_in: nil), by: "alex", now: NOW).refresh_expires_at
    assert_nil TiktokConnection.store!(grant(refresh_expires_in: 0), by: "alex", now: NOW).refresh_expires_at
    assert_nil TiktokConnection.store!(grant(refresh_expires_in: "soon"), by: "alex", now: NOW).refresh_expires_at
  end

  test "[unit] rotate! saves a refresh token that differs, with when and its new expiry" do
    connection = TiktokConnection.store!(grant, by: "alex", now: NOW)

    wrote = connection.rotate!(grant(refresh_token: "rft.synthetic-rotated", refresh_expires_in: 100), now: NOW + 1.day)

    assert wrote
    connection.reload
    assert_equal "rft.synthetic-rotated", connection.refresh_token
    assert_equal NOW + 1.day, connection.refreshed_at
    assert_equal NOW + 1.day + 100, connection.refresh_expires_at
    assert_equal NOW, connection.connected_at, "a rotation is not a new sign-in"
  end

  test "[unit] rotate! writes nothing for the same token, or for none" do
    connection = TiktokConnection.store!(grant, by: "alex", now: NOW)
    before = connection.updated_at

    assert_not connection.rotate!(grant, now: NOW + 1.day)
    assert_not connection.rotate!(grant(refresh_token: nil), now: NOW + 1.day)
    assert_not connection.rotate!(grant(refresh_token: ""), now: NOW + 1.day)

    connection.reload
    assert_equal TOKEN, connection.refresh_token
    assert_nil connection.refreshed_at
    assert_equal before, connection.updated_at
  end
end
