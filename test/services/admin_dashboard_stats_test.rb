require "test_helper"

# [unit] The dashboard cards' counts.
class AdminDashboardStatsTest < ActiveSupport::TestCase
  setup do
    @now = Time.zone.parse("2026-11-03 12:00:00")
    @stats = AdminDashboardStats.new(viewer: users(:alex), now: @now)
  end

  test "users: total, newest date, and the new ones inside the window only" do
    User.update_all(created_at: @now - 30.days)
    inside = User.create!(email: "new@example.test", first_name: "New", created_at: @now - 2.days)
    outside = User.create!(email: "old@example.test", first_name: "Old", created_at: @now - 8.days)

    card = @stats.users
    assert_equal User.count, card.total
    assert_equal inside.created_at, card.last_new_at
    assert_equal 1, card.new_this_week
    refute_equal outside.created_at, card.last_new_at
  end

  test "sessions answers zero and nobody without the recording engine" do
    @stats.stub(:sessions_recorded?, false) do
      card = @stats.sessions
      assert_equal 0, card.this_week
      assert_nil card.last_user
    end
  end

  test "agents counts the roster and open setups" do
    card = @stats.agents
    assert_equal Agent.count, card.total
    assert_equal AgentSetup.open_setups.count, card.pending
  end

  test "applications splits live from pending" do
    list = ApplicationsWatchList.build(AppOwnership.visible_apps(users(:alex)).to_a, admin: true)
    card = @stats.applications
    assert_equal [ list.live.size, list.pending.size ], [ card.live, card.pending ]
  end
end
