require "test_helper"

# A socket that was admitted stays open after the session behind it is revoked
# unless something closes it: /cable checks only at connect. These tests open a
# REAL connection through ApplicationCable::Connection, revoke the user the way
# the app does, and assert the disconnect lands on that connection's own internal
# channel, and that the reconnect it asks for is then refused.
class CableRevocationConnectionTest < ActionCable::Connection::TestCase
  tests ApplicationCable::Connection
  include ActionCable::TestHelper

  setup do
    @admin = User.create!(email: "ops-admin@example.com", name: "Ops Admin", role: "admin")
  end

  def session_for(user, token: user.session_token)
    { Studio.session_key.to_s => user.id, "session_token" => token }
  end

  def disconnects_on(channel)
    broadcasts(channel).map { |raw| ActiveSupport::JSON.decode(raw) }.select { |m| m["type"] == "disconnect" }
  end

  test "[integration] a demoted admin's open cable connection is closed" do
    connect session: session_for(@admin)
    channel = connection.send(:internal_channel)
    assert_equal @admin, connection.current_user

    @admin.update!(role: "viewer")

    assert_equal 1, disconnects_on(channel).size, "the open socket must be told to drop"
    assert_reject_connection { connect session: session_for(@admin.reload) }
  end

  test "[integration] a rotated token closes the open connection and refuses the reconnect" do
    old_token = @admin.session_token
    connect session: session_for(@admin)
    channel = connection.send(:internal_channel)

    @admin.regenerate_session_token!

    assert_equal 1, disconnects_on(channel).size
    assert_reject_connection { connect session: session_for(@admin, token: old_token) }
  end
end

# Sign-out does not rotate the token, so the browser's socket would stay
# identified as the user. clear_app_session drops it.
class CableRevocationSignOutTest < ActionDispatch::IntegrationTest
  include ActionCable::TestHelper

  test "[integration] signing out disconnects the user's open sockets" do
    admin = users(:alex)
    log_in_as(admin)
    channel = "action_cable/#{admin.to_gid_param}"
    before = broadcasts(channel).size

    get logout_path

    assert_redirected_to login_path
    assert_equal before + 1, broadcasts(channel).size
  end
end
