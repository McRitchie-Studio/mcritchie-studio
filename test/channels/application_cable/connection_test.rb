require "test_helper"

# /cable admits admins only (app/channels/application_cable/connection.rb). The
# session is the one the engine's controller auth reads: session[Studio.session_key]
# names the user and session[:session_token] must match the user's rotating token.
class ApplicationCable::ConnectionTest < ActionCable::Connection::TestCase
  setup do
    @admin = users(:alex)
    @viewer = users(:viewer)
    [@admin, @viewer].each { |user| user.update_column(:session_token, SecureRandom.hex(32)) }
  end

  def session_for(user, token: user.session_token)
    { Studio.session_key.to_s => user.id, "session_token" => token }
  end

  test "[unit] a visitor with no session is rejected" do
    assert_reject_connection { connect }
  end

  test "[unit] a signed-in non-admin is rejected" do
    assert_not @viewer.admin?
    assert_reject_connection { connect session: session_for(@viewer) }
  end

  test "[unit] an admin connects, identified as that user" do
    connect session: session_for(@admin)
    assert_equal @admin, connection.current_user
  end

  test "[unit] an admin whose session token was rotated is rejected" do
    assert_reject_connection { connect session: session_for(@admin, token: "stale") }
  end

  test "[unit] an admin session with no session token is rejected" do
    assert_reject_connection { connect session: { Studio.session_key.to_s => @admin.id } }
  end

  test "[unit] a session naming a user who no longer exists is rejected" do
    assert_reject_connection { connect session: { Studio.session_key.to_s => 0, "session_token" => "x" } }
  end
end
