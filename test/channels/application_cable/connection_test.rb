require "test_helper"

# /cable admits any signed-in user with a current session
# (app/channels/application_cable/connection.rb); what each may hear is the
# channel's check (TurboStreamsChannelAdminTest, CtoChatChannelTest). The session is
# the one the engine's controller auth reads: session[Studio.session_key] names the
# user and session[:session_token] must match the user's rotating token.
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

  test "[unit] a signed-in non-admin connects, identified as that user (channels decide what they hear)" do
    assert_not @viewer.admin?
    connect session: session_for(@viewer)
    assert_equal @viewer, connection.current_user
  end

  test "[unit] a non-admin whose session token was rotated is rejected" do
    assert_reject_connection { connect session: session_for(@viewer, token: "stale") }
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

  # The engine's device-session check (Studio::UserSession.ended?) is stubbed so
  # these run on an engine with or without the helper; the engine's own suite
  # proves which cookies it calls ended.
  def with_device_session_verdict(ended)
    seen = []
    klass = Studio::UserSession.singleton_class
    had = klass.method_defined?(:ended?)
    klass.alias_method(:ended_before_stub?, :ended?) if had
    klass.define_method(:ended?) { |store, **| seen << store; ended }
    yield seen
  ensure
    klass.remove_method(:ended?)
    if had
      klass.alias_method(:ended?, :ended_before_stub?)
      klass.remove_method(:ended_before_stub?)
    end
  end

  test "[unit] a logged-out device's cookie (an ended device session) is rejected" do
    with_device_session_verdict(true) do |seen|
      assert_reject_connection { connect session: session_for(@viewer) }
      assert_equal @viewer.id, seen.last[Studio.session_key.to_s], "the check reads the connection's own session"
    end
  end

  test "[unit] a live device session connects, identified as that user" do
    with_device_session_verdict(false) do |seen|
      connect session: session_for(@viewer)
      assert_equal @viewer, connection.current_user
      assert_equal 1, seen.size
    end
  end

  test "[unit] a visitor is rejected before the device-session check reads anything" do
    with_device_session_verdict(false) do |seen|
      assert_reject_connection { connect }
      assert_empty seen
    end
  end
end
