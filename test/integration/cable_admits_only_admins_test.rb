require "test_helper"
require "action_cable/channel/test_case" # ConnectionStub, for the board-stream subscribe below

# The board's live stream reaches admins only, proven through the real sign-in
# door: a user logs in by magic link, the hub's session cookie is decoded the way
# the cookie store decodes it, and that session opens (or fails to open)
# ApplicationCable::Connection. A visitor gets no connection. Since the CTO web
# chat a signed-in non-admin does get one, and the deployments board's signed
# stream name refuses them at subscribe (ApplicationCable::TurboStreamsAdminOnly);
# an admin's subscribes to the live board.
class CableAdmitsOnlyAdminsTest < ActionDispatch::IntegrationTest
  SIGNED_STREAM = /signed-stream-name="([^"]+)"/

  # The session a browser would present on /cable: the hub's session cookie,
  # decrypted with the app's own key, cookie name included.
  def cable_session_from_cookie
    key = Rails.application.config.session_options.fetch(:key)
    env = Rails.application.env_config.merge("HTTP_COOKIE" => "#{key}=#{CGI.escape(cookies[key].to_s)}")
    ActionDispatch::Request.new(env).cookie_jar.encrypted[key] || {}
  end

  def open_cable(session_hash)
    env = Rack::MockRequest.env_for("/cable", "rack.session" => session_hash)
    connection = ApplicationCable::Connection.new(ActionCable.server, env)
    connection.connect
    connection
  end

  test "[integration] a visitor gets no board stream name and no cable connection" do
    get deployments_path
    assert_response :redirect
    assert_no_match SIGNED_STREAM, response.body

    assert_raises(ActionCable::Connection::Authorization::UnauthorizedError) do
      open_cable(cable_session_from_cookie)
    end
  end

  test "[integration] a signed-in non-admin gets no board stream name, and the cable refuses them the board stream" do
    viewer = users(:viewer)
    log_in_as(viewer)
    session_hash = cable_session_from_cookie
    assert_equal viewer.id, session_hash[Studio.session_key.to_s], "the login should have written the session the cable reads"

    get deployments_path
    assert_response :redirect
    assert_no_match SIGNED_STREAM, response.body

    connection = open_cable(session_hash)
    assert_equal viewer, connection.current_user, "the cable admits a signed-in user (the CTO web chat needs it)"

    stub = ActionCable::Channel::ConnectionStub.new(current_user: connection.current_user)
    board = Turbo::StreamsChannel.new(stub, "board", { "signed_stream_name" => Turbo::StreamsChannel.signed_stream_name(DeploymentsBroadcaster::STREAM) })
    board.subscribe_to_channel
    assert_equal "reject_subscription", stub.transmissions.last&.dig("type"), "the board stream refuses a non-admin, so nothing streams to them"
  end

  test "[integration] an admin's cookie opens the cable and the board's signed stream is the live deployments stream" do
    admin = users(:alex)
    log_in_as(admin)
    connection = open_cable(cable_session_from_cookie)
    assert_equal admin, connection.current_user

    get deployments_path
    assert_response :success
    signed = response.body[SIGNED_STREAM, 1]
    assert signed, "the admin board should render a turbo_stream_from source"
    assert_equal DeploymentsBroadcaster::STREAM,
                 Turbo::StreamsChannel.verified_stream_name(CGI.unescapeHTML(signed))
  end
end
