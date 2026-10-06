require "test_helper"

# Behind the admin-only connection, the board's live updates still flow: an admin's
# connection subscribes to the signed "deployments" stream name the board renders
# and a DeploymentsBroadcaster-style broadcast lands on it.
class TurboStreamsChannelAdminTest < ActionCable::Channel::TestCase
  tests Turbo::StreamsChannel

  test "[integration] an admin subscribes to the signed deployments stream and receives its broadcast" do
    stub_connection current_user: users(:alex)
    subscribe signed_stream_name: Turbo::StreamsChannel.signed_stream_name(DeploymentsBroadcaster::STREAM)

    assert subscription.confirmed?
    assert_has_stream DeploymentsBroadcaster::STREAM

    assert_broadcasts(DeploymentsBroadcaster::STREAM, 1) do
      Turbo::StreamsChannel.broadcast_replace_to(DeploymentsBroadcaster::STREAM, target: "probe", html: "<p>live</p>")
    end
  end

  test "[unit] a forged stream name is refused" do
    stub_connection current_user: users(:alex)
    subscribe signed_stream_name: "deployments"
    assert subscription.rejected?
  end
end
