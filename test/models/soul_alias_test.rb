require "test_helper"

# [unit] The persona seat is `alex` again (ritch-renamed-alex, 2026-10-25); `ray`
# and `xan` are its RETIRED slugs and resolve to it (Task::SOUL_ALIASES). The
# alias is READ-ONLY: every writer that stamps a soul stamps the canonical slug,
# so the record never carries `ray` again after RenameRaySoulToAlex repointed it.
# The orchestrator's grader key and devops lane went to Mason, not the persona:
# ActionGrade::GRADER_ALIASES and DevopsShift::LANE_ALIASES send `ray` there.
class SoulAliasTest < ActiveSupport::TestCase
  test "the roster carries alex and neither retired slug" do
    assert_includes Task::SOUL_ROSTER, "alex"
    refute_includes Task::SOUL_ROSTER, "ray", "the retired slug is an alias, not a roster entry"
    refute_includes Task::SOUL_ROSTER, "xan", "the retired slug is an alias, not a roster entry"
    assert_equal({ "ray" => "alex", "xan" => "alex" }, Task::SOUL_ALIASES, "chain-flattened: xan never lands on ray")
  end

  test "canonical_soul maps the retired slugs and passes every other value through" do
    assert_equal "alex", Task.canonical_soul("ray")
    assert_equal "alex", Task.canonical_soul(" ray ")
    assert_equal "alex", Task.canonical_soul("xan")
    assert_equal "alex", Task.canonical_soul("alex"), "alex is canonical, not an alias any more"
    assert_equal "carl", Task.canonical_soul("carl")
    assert_equal "", Task.canonical_soul(nil)
    assert_equal "stefon", Task.canonical_soul("stefon"), "a typo is not an alias — it still fails .soul?"
  end

  test "soul? recognises the seat under every slug and nothing that is none" do
    assert Task.soul?("alex")
    assert Task.soul?("ray"), "the retired slug still names a soul while the alias stands"
    assert Task.soul?("xan"), "so does the slug ray-slug-rename retired"
    refute Task.soul?("alex-docs"), "a slug retired without an alias stays unknown"
    refute Task.soul?("stefon")
  end

  test "a build claim made as ray stamps the builder as alex" do
    task = Task.create!(title: "alias stamp sample", stage: "designed",
                        metadata: { "devops" => { "shape" => "backend" } })
    Current.task_event_actor = "ray"
    task.update!(stage: "building")

    devops = task.reload.devops
    assert_equal "alex", devops["built_by"], "the stamp is canonical, never the retired slug"
    assert_equal %w[alex], devops["builders"]
  ensure
    Current.task_event_actor = nil
  end

  test "an author set stamped under ray reads as alex and dedupes against an alex claim" do
    task = Task.create!(title: "alias dedupe sample", stage: "designed",
                        metadata: { "devops" => { "shape" => "backend" } })
    # A row exactly as a database the migration has not reached holds it.
    task.update_columns(metadata: { "devops" => { "shape" => "backend", "built_by" => "ray", "builders" => ["ray"] } })

    assert_equal "alex", task.reload.devops_built_by
    assert_equal %w[alex], task.devops_builders

    Current.task_event_actor = "alex"
    task.update!(stage: "building")
    assert_equal %w[alex], task.reload.devops["builders"], "ray and alex are ONE author, not two"
  ensure
    Current.task_event_actor = nil
  end

  test "an activity attributed to ray lands on alex; an unknown soul still drops to nil" do
    assert_equal "alex", AgentActivity.normalize_agent_value("ray")
    assert_equal "alex", AgentActivity.normalize_agent_value("RAY")
    assert_equal "alex", AgentActivity.normalize_agent_value("xan")
    assert_nil AgentActivity.normalize_agent_value("stefon")
    assert_includes AgentActivity::SOULS, "alex"
    refute_includes AgentActivity::SOULS, "ray"
  end

  test "a grade posted under the retired key is stored under mason, never the persona" do
    span = AgentActivity.create!(session_id: "alias-grade", category: "Explore", reason_slug: "read the seat",
                                 opened_at: Time.current, closed_at: Time.current, outcome_slug: "done")
    grade = ActionGrade.create!(agent_activity: span, grader: "ray", disposition: "good", slug: "lands on mason")

    assert_equal ActionGrade::MASON, grade.reload.grader
    assert grade.mason?
    assert grade.ray?, "the retired predicate answers the same question for one release"
    assert_equal [grade.id], ActionGrade.by_grader("ray").pluck(:id), "the scope reads through the alias too"
    refute ActionGrade.new(agent_activity: span, grader: "alex", disposition: "good", slug: "x").valid?,
           "the persona grades nothing: a posted alex is refused, never relabelled"
  end

  test "the devops shift lane typed as ray or xan is the mason lane" do
    outcome = DevopsShift.acquire(lane: "ray", session: "sess-alias", nonce: "n1")
    assert outcome.acquired
    assert_equal "mason", outcome.shift.lane
    assert_equal "mason", DevopsShift.canonical_lane("xan")
    assert_includes DevopsShift::LANES, "mason"
    refute_includes DevopsShift::LANES, "ray"
    refute_includes DevopsShift::LANES, "alex"
  end
end
