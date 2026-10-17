require "test_helper"

# Turbo::StreamsChannel is admins only (ApplicationCable::TurboStreamsAdminOnly):
# an admin's connection subscribes to the signed "deployments" stream name the
# board renders and a DeploymentsBroadcaster-style broadcast lands on it, while a
# signed-in non-admin, whom /cable now admits for the CTO web chat, is refused
# even holding the signed name.
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

  test "[unit] a signed-in non-admin holding the signed deployments name is refused" do
    stub_connection current_user: users(:viewer)
    subscribe signed_stream_name: Turbo::StreamsChannel.signed_stream_name(DeploymentsBroadcaster::STREAM)

    assert subscription.rejected?
    assert_no_streams
  end

  test "[unit] a forged stream name is refused" do
    stub_connection current_user: users(:alex)
    subscribe signed_stream_name: "deployments"
    assert subscription.rejected?
  end
end
