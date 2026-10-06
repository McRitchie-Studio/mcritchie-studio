require "test_helper"

# /cable checks admin and the session token only at CONNECT
# (app/channels/application_cable/connection.rb), so a socket opened before a
# revocation would keep streaming board HTML until it reconnected. User drops the
# user's remote connections after commit whenever their token rotates, they lose
# admin, or the row is destroyed. The disconnect travels on the connection's
# internal channel, "action_cable/<user gid>", which is what these tests read.
class UserCableRevocationTest < ActiveSupport::TestCase
  include ActionCable::TestHelper

  setup do
    # Not a PARKED_IDENTITIES email: assign_parked_identity would re-promote a
    # parked admin on the very save that demotes it.
    @admin = User.create!(email: "ops-admin@example.com", name: "Ops Admin", role: "admin")
  end

  def internal_channel(user)
    "action_cable/#{user.to_gid_param}"
  end

  def disconnects(user)
    broadcasts(internal_channel(user)).map { |raw| ActiveSupport::JSON.decode(raw) }
                                      .select { |msg| msg["type"] == "disconnect" }
  end

  test "[unit] regenerate_session_token! disconnects remote connections for the user" do
    @admin.regenerate_session_token!

    assert_equal 1, disconnects(@admin).size
    assert_equal true, disconnects(@admin).first["reconnect"], "a valid session must be free to reconnect"
  end

  test "[unit] losing admin disconnects the user's remote connections" do
    @admin.update!(role: "viewer")

    assert_equal 1, disconnects(@admin).size
  end

  test "[unit] destroying the user disconnects their remote connections" do
    @admin.destroy!

    assert_equal 1, disconnects(@admin).size
  end

  test "[unit] a rolled-back rotation drops no sockets" do
    User.transaction do
      @admin.regenerate_session_token!
      @admin.update!(role: "viewer")
      raise ActiveRecord::Rollback
    end

    assert_empty disconnects(@admin)
  end

  test "[unit] the disconnect waits for the commit" do
    User.transaction do
      @admin.regenerate_session_token!
      assert_empty disconnects(@admin), "no socket may drop before the write is durable"
    end

    assert_equal 1, disconnects(@admin).size, "two revocations in one transaction drop once"
  end

  test "[unit] an unrelated save drops no sockets" do
    @admin.update!(name: "Renamed Admin")
    viewer = users(:viewer)
    viewer.update!(role: "admin")

    assert_empty disconnects(@admin)
    assert_empty disconnects(viewer), "a promotion revokes nothing"
  end

  test "[unit] creating a user drops no sockets" do
    user = User.create!(email: "fresh@example.com", role: "viewer")

    assert_empty disconnects(user)
  end

  test "[unit] a broadcast failure never fails the committed write" do
    ActionCable.server.stub(:remote_connections, -> { raise Redis::CannotConnectError, "down" }) do
      assert_nothing_raised { @admin.regenerate_session_token! }
    end

    assert_not_nil @admin.reload.session_token
  end
end
