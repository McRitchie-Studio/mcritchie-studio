require "test_helper"

class AgentTest < ActiveSupport::TestCase
  test "initials_for upcases the first non-blank char, ? for blank" do
    assert_equal "S", Agent.initials_for("shannon")
    assert_equal "A", Agent.initials_for("  avi ")
    assert_equal "?", Agent.initials_for("")
    assert_equal "?", Agent.initials_for(nil)
  end

  test "avatar_color_for is deterministic and from the AVATAR_COLORS palette" do
    color = Agent.avatar_color_for("steffon")
    assert_includes Agent::AVATAR_COLORS, color
    assert_equal color, Agent.avatar_color_for("steffon")
    # different seeds can land on different hues, but always within the palette
    assert_includes Agent::AVATAR_COLORS, Agent.avatar_color_for("avi")
  end

  test "instance avatar helpers delegate to the shared class methods" do
    agent = Agent.new(name: "Shannon", slug: "shannon")
    assert_equal Agent.initials_for("Shannon"), agent.avatar_initials
    assert_equal Agent.avatar_color_for("shannon"), agent.avatar_color
  end

  # [unit] Regression: a soul's display name can differ from its slug (slug `xan`
  # read "Ray" until ray-slug-rename). Creating the row with both must keep the
  # given slug, or the seed on a fresh database makes a row keyed by the name and
  # orphans every child of the real slug.
  test "an explicit slug survives a create whose name parameterizes differently" do
    agent = Agent.create!(name: "Mason", slug: "alex-regression", status: "active", agent_type: "orchestrator")
    assert_equal "alex-regression", agent.reload.slug
  end
end
