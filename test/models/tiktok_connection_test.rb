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

    wrote = connection.rotate!(grant(refresh_token: "rft.synthetic-rotated", refresh_expires_in: 100), sent: TOKEN, now: NOW + 1.day)

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

    assert_not connection.rotate!(grant, sent: TOKEN, now: NOW + 1.day)
    assert_not connection.rotate!(grant(refresh_token: nil), sent: TOKEN, now: NOW + 1.day)
    assert_not connection.rotate!(grant(refresh_token: ""), sent: TOKEN, now: NOW + 1.day)

    connection.reload
    assert_equal TOKEN, connection.refresh_token
    assert_nil connection.refreshed_at
    assert_equal before, connection.updated_at
  end

  # Two refreshes were sent with the same stored token. TikTok answered one
  # with T2 and it was saved; the other answers late with T3. The row no
  # longer holds what the late one sent, so it writes nothing.
  test "[unit] a late rotation cannot store over a newer one (out of order)" do
    first = TiktokConnection.store!(grant, by: "alex", now: NOW)
    late = TiktokConnection.find(first.id) # a second process's copy of the same row, read before the first write

    assert first.rotate!(grant(refresh_token: "rft.synthetic-T2"), sent: TOKEN, now: NOW + 1.hour)
    assert_not late.rotate!(grant(refresh_token: "rft.synthetic-T3"), sent: TOKEN, now: NOW + 2.hours)

    row = TiktokConnection.find(first.id)
    assert_equal "rft.synthetic-T2", row.refresh_token
    assert_equal NOW + 1.hour, row.refreshed_at
  end

  test "[unit] a refresh racing a new sign-in cannot overwrite the sign-in's token" do
    stale = TiktokConnection.store!(grant, by: "alex", now: NOW)
    TiktokConnection.store!(grant(refresh_token: "rft.synthetic-new-sign-in"), by: "alex", now: NOW + 1.hour)

    assert_not stale.rotate!(grant(refresh_token: "rft.synthetic-from-old-refresh"), sent: TOKEN, now: NOW + 2.hours)

    row = TiktokConnection.find(stale.id)
    assert_equal "rft.synthetic-new-sign-in", row.refresh_token
    assert_nil row.refreshed_at
  end

  test "[unit] the rotation is written under the row's lock" do
    connection = TiktokConnection.store!(grant, by: "alex", now: NOW)
    sql = []
    ActiveSupport::Notifications.subscribed(->(*, payload) { sql << payload[:sql] }, "sql.active_record") do
      connection.rotate!(grant(refresh_token: "rft.synthetic-T2"), sent: TOKEN)
    end

    lock = sql.index { |line| line.include?("FOR UPDATE") }
    update = sql.index { |line| line.start_with?(%(UPDATE "tiktok_connections")) }
    assert lock, "the row is read again FOR UPDATE"
    assert_operator lock, :<, update
  end

  test "[unit] a rotation for a row a disconnect deleted writes nothing and raises nothing" do
    connection = TiktokConnection.store!(grant, by: "alex", now: NOW)
    TiktokConnection.delete_all

    assert_not connection.rotate!(grant(refresh_token: "rft.synthetic-T2"), sent: TOKEN)
    assert_equal 0, TiktokConnection.count
  end

  # Swaps the app's encryption keys for the block: what a lost or rotated key is.
  def with_other_encryption_key
    other = ActiveRecord::Encryption::DerivedSecretKeyProvider.new("another-synthetic-primary-key-987654321")
    ActiveRecord::Encryption.with_encryption_context(key_provider: other) { yield }
  end

  test "[unit] a row stored under another key is unreadable, and readable again under its own" do
    connection = TiktokConnection.store!(grant, by: "alex", now: NOW)
    assert connection.readable? # the control

    with_other_encryption_key do
      row = TiktokConnection.find(connection.id)
      assert_raises(ActiveRecord::Encryption::Errors::Decryption) { row.refresh_token }
      assert_not row.readable?
      assert_equal "open-synthetic-1", row.account, "what is stored in the clear still reads"
    end

    assert TiktokConnection.find(connection.id).readable?
  end

  test "[unit] signing in again replaces a row that can no longer be read" do
    old = TiktokConnection.store!(grant, by: "alex", now: NOW)

    with_other_encryption_key do
      assert_no_difference -> { TiktokConnection.count } do
        TiktokConnection.store!(grant(refresh_token: "rft.synthetic-after-key-change"), by: "alex", now: NOW + 1.day)
      end

      row = TiktokConnection.current
      assert_not_equal old.id, row.id
      assert row.readable?
      assert_equal "rft.synthetic-after-key-change", row.refresh_token
    end
  end

  # The delete of the unreadable row and the save that replaces it are one
  # transaction: a save that fails must not leave the account with no row.
  test "[unit] a failed replacement of an unreadable row leaves that row in place" do
    old = TiktokConnection.store!(grant, by: "alex", now: NOW)

    with_other_encryption_key do
      assert_no_difference -> { TiktokConnection.count } do
        assert_raises(ActiveRecord::RecordInvalid) do
          TiktokConnection.store!(grant(refresh_token: ""), by: "alex", now: NOW + 1.day)
        end
      end
      assert TiktokConnection.exists?(old.id), "the row the sign-in set out to replace is still there"
    end

    assert_equal TOKEN, TiktokConnection.find(old.id).refresh_token, "and still reads under its own key"
  end

  test "[unit] encryption_ready? is Fact's predicate, and the three names are Fact's" do
    assert TiktokConnection.encryption_ready?
    Fact.stub(:encryption_ready?, false) { assert_not TiktokConnection.encryption_ready? }
    assert_equal Fact::ENCRYPTION_ENV, TiktokConnection::ENCRYPTION_ENV
    assert_equal 3, TiktokConnection::ENCRYPTION_ENV.size
  end
end
