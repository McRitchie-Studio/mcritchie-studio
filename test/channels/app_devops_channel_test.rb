require "test_helper"

# [unit] AppDevopsChannel: an app's status-card stream is heard only by a viewer
# who may manage that app (its owner or an admin), and only when the signed name
# is an app-devops stream.
class AppDevopsChannelTest < ActionCable::Channel::TestCase
  setup do
    @owner = User.create!(email: "owner@turf.example", name: "Turf Owner", role: "viewer")
    @membership = AppMembership.create!(app: apps(:turf_monster), user: @owner)
  end

  def signed(app_slug) = AppDevopsChannel.signed_stream_name(AppDevopsStages::Live.stream_name(app_slug))

  test "the app's owner and an admin subscribe" do
    stub_connection current_user: @owner
    subscribe signed_stream_name: signed("turf-monster")
    assert subscription.confirmed?
    assert_has_stream "app_devops:turf-monster"

    stub_connection current_user: users(:alex)
    subscribe signed_stream_name: signed("mcritchie-studio")
    assert subscription.confirmed?
  end

  test "another app's stream, an ended ownership, an unsigned or foreign name are refused" do
    stub_connection current_user: @owner
    subscribe signed_stream_name: signed("mcritchie-studio")
    assert subscription.rejected?

    subscribe signed_stream_name: "app_devops:turf-monster"
    assert subscription.rejected?

    subscribe signed_stream_name: AppDevopsChannel.signed_stream_name("deployments")
    assert subscription.rejected?

    @membership.destroy!
    subscribe signed_stream_name: signed("turf-monster")
    assert subscription.rejected?
  end
end
