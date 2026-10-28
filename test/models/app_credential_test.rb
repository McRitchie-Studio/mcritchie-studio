require "test_helper"

# [unit] A satellite app's own credential (AppCredential): the secret is never
# stored, a live one authenticates, a revoked or re-minted one does not.
class AppCredentialTest < ActiveSupport::TestCase
  test "issue! returns the secret once and keeps only its digest" do
    row, secret = AppCredential.issue!(app_slug: "alex-build", purpose: "agent-chat", issued_by: "test")

    assert secret.start_with?("hubchat_")
    assert_operator secret.length, :>, 40
    assert_equal Digest::SHA256.hexdigest(secret), row.token_digest
    refute_includes row.attributes.values.map(&:to_s), secret, "no column holds the secret"
    assert_equal row, AppCredential.authenticate(secret, purpose: "agent-chat")
  end

  test "authenticate refuses a wrong, empty, revoked or other-purpose secret" do
    row, secret = AppCredential.issue!(app_slug: "alex-build", purpose: "agent-chat")

    assert_nil AppCredential.authenticate("#{secret}x", purpose: "agent-chat")
    assert_nil AppCredential.authenticate("", purpose: "agent-chat")
    assert_nil AppCredential.authenticate(secret, purpose: "something-else")
    row.revoke!(by: "test")
    assert_nil AppCredential.authenticate(secret, purpose: "agent-chat")
  end

  test "minting again revokes the app's live credential" do
    first, old_secret = AppCredential.issue!(app_slug: "alex-build", purpose: "agent-chat")
    second, new_secret = AppCredential.issue!(app_slug: "alex-build", purpose: "agent-chat")

    assert first.reload.revoked?
    assert_nil AppCredential.authenticate(old_secret, purpose: "agent-chat")
    assert_equal second, AppCredential.authenticate(new_secret, purpose: "agent-chat")
  end

  test "a use stamps last_used_at, at most every TOUCH_EVERY" do
    row, secret = AppCredential.issue!(app_slug: "alex-build", purpose: "agent-chat")
    now = Time.current
    AppCredential.authenticate(secret, purpose: "agent-chat", now: now)
    assert_in_delta now, row.reload.last_used_at, 1
    AppCredential.authenticate(secret, purpose: "agent-chat", now: now + 1.minute)
    assert_in_delta now, row.reload.last_used_at, 1, "a poll a minute later writes nothing"
  end

  test "the database holds one live credential per app and purpose" do
    AppCredential.issue!(app_slug: "alex-build", purpose: "agent-chat")
    assert_raises(ActiveRecord::RecordNotUnique) do
      AppCredential.create!(app_slug: "alex-build", purpose: "agent-chat", token_digest: AppCredential.digest("second"))
    end
    AppCredential.issue!(app_slug: "alex-build", purpose: "agent-chat")
    assert_equal 1, AppCredential.live.where(app_slug: "alex-build").count
    assert_equal 2, AppCredential.where(app_slug: "alex-build").count, "revoked rows stay as the record"
  end

  test "the database refuses an unknown purpose" do
    assert_raises(ActiveRecord::StatementInvalid) do
      AppCredential.insert_all!([ { app_slug: "x", purpose: "other", token_digest: "d", created_at: Time.current, updated_at: Time.current } ])
    end
  end
end
