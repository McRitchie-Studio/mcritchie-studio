require "test_helper"

# [unit] CtoChatChannel: a CTO web chat stream is heard only by the one user it
# names, while they may manage that app. A copied, forged or stale name hears
# nothing, and an admin hears only their own chat.
class CtoChatChannelTest < ActionCable::Channel::TestCase
  setup do
    @owner = User.create!(email: "owner@turf.example", name: "Turf Owner", role: "viewer")
    @membership = AppMembership.create!(app: apps(:turf_monster), user: @owner)
  end

  def signed(app_slug, user)
    CtoChatChannel.signed_stream_name(AgentMessages::WebChat.stream_name(app_slug, user.id))
  end

  test "the app's owner subscribes to their own chat stream" do
    stub_connection current_user: @owner
    subscribe signed_stream_name: signed("turf-monster", @owner)

    assert subscription.confirmed?
    assert_has_stream AgentMessages::WebChat.stream_name("turf-monster", @owner.id)
  end

  test "another user's chat stream is refused, admin or not" do
    stub_connection current_user: users(:alex)
    subscribe signed_stream_name: signed("turf-monster", @owner)
    assert subscription.rejected?
  end

  test "an owner is refused another app's chat, and their own once the ownership ends" do
    stub_connection current_user: @owner
    subscribe signed_stream_name: signed("mcritchie-studio", @owner)
    assert subscription.rejected?

    @membership.destroy!
    subscribe signed_stream_name: signed("turf-monster", @owner)
    assert subscription.rejected?
  end

  test "an unsigned or non-chat stream name is refused" do
    stub_connection current_user: @owner
    subscribe signed_stream_name: AgentMessages::WebChat.stream_name("turf-monster", @owner.id)
    assert subscription.rejected?

    subscribe signed_stream_name: CtoChatChannel.signed_stream_name("deployments")
    assert subscription.rejected?
  end

  test "an admin subscribes to their own chat with any app" do
    stub_connection current_user: users(:alex)
    subscribe signed_stream_name: signed("turf-monster", users(:alex))
    assert subscription.confirmed?
  end
end
