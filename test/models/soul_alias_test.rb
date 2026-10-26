require "test_helper"

# [unit] The orchestrator seat is `ray`; `alex` is its RETIRED slug and resolves
# to it for one release (Task::SOUL_ALIASES). The alias is READ-ONLY: every
# writer that stamps a soul stamps the canonical slug, so the record never
# carries `alex` again after RenameAlexSoulToXan repointed it.
class SoulAliasTest < ActiveSupport::TestCase
  test "the roster carries ray and neither retired slug" do
    assert_includes Task::SOUL_ROSTER, "ray"
    refute_includes Task::SOUL_ROSTER, "alex", "the retired slug is an alias, not a roster entry"
    refute_includes Task::SOUL_ROSTER, "xan", "the retired slug is an alias, not a roster entry"
    assert_equal({ "alex" => "ray", "xan" => "ray" }, Task::SOUL_ALIASES, "chain-flattened: alex never lands on xan")
  end

  test "canonical_soul maps the retired slug and passes every other value through" do
    assert_equal "ray", Task.canonical_soul("alex")
    assert_equal "ray", Task.canonical_soul(" alex ")
    assert_equal "ray", Task.canonical_soul("xan")
    assert_equal "ray", Task.canonical_soul("ray")
    assert_equal "carl", Task.canonical_soul("carl")
    assert_equal "", Task.canonical_soul(nil)
    assert_equal "stefon", Task.canonical_soul("stefon"), "a typo is not an alias — it still fails .soul?"
  end

  test "soul? recognises the seat under both slugs and nothing that is neither" do
    assert Task.soul?("ray")
    assert Task.soul?("alex"), "the retired slug still names a soul while the alias stands"
    assert Task.soul?("xan"), "so does the slug ray-slug-rename retired"
    refute Task.soul?("alex-docs"), "a slug retired without an alias stays unknown"
    refute Task.soul?("stefon")
  end

  test "a build claim made as alex stamps the builder as ray" do
    task = Task.create!(title: "alias stamp sample", stage: "designed",
                        metadata: { "devops" => { "shape" => "backend" } })
    Current.task_event_actor = "alex"
    task.update!(stage: "building")

    devops = task.reload.devops
    assert_equal "ray", devops["built_by"], "the stamp is canonical, never the retired slug"
    assert_equal %w[ray], devops["builders"]
  ensure
    Current.task_event_actor = nil
  end

  test "an author set stamped under alex reads as ray and dedupes against a ray claim" do
    task = Task.create!(title: "alias dedupe sample", stage: "designed",
                        metadata: { "devops" => { "shape" => "backend" } })
    # A row exactly as a database the migration has not reached holds it.
    task.update_columns(metadata: { "devops" => { "shape" => "backend", "built_by" => "alex", "builders" => ["alex"] } })

    assert_equal "ray", task.reload.devops_built_by
    assert_equal %w[ray], task.devops_builders

    Current.task_event_actor = "ray"
    task.update!(stage: "building")
    assert_equal %w[ray], task.reload.devops["builders"], "alex and ray are ONE author, not two"
  ensure
    Current.task_event_actor = nil
  end

  test "an activity attributed to alex lands on ray; an unknown soul still drops to nil" do
    assert_equal "ray", AgentActivity.normalize_agent_value("alex")
    assert_equal "ray", AgentActivity.normalize_agent_value("RAY")
    assert_nil AgentActivity.normalize_agent_value("stefon")
    assert_includes AgentActivity::SOULS, "ray"
    refute_includes AgentActivity::SOULS, "alex"
  end

  test "a grade posted under the retired slug is stored under ray" do
    span = AgentActivity.create!(session_id: "alias-grade", category: "Explore", reason_slug: "read the seat",
                                 opened_at: Time.current, closed_at: Time.current, outcome_slug: "done")
    grade = ActionGrade.create!(agent_activity: span, grader: "alex", disposition: "good", slug: "lands on ray")

    assert_equal ActionGrade::MASON, grade.reload.grader
    assert grade.mason?
    assert grade.alex?, "the retired predicate answers the same question for one release"
    assert_equal [grade.id], ActionGrade.by_grader("alex").pluck(:id), "the scope reads through the alias too"
  end

  test "the devops shift lane typed as alex is the ray lane" do
    outcome = DevopsShift.acquire(lane: "alex", session: "sess-alias", nonce: "n1")
    assert outcome.acquired
    assert_equal "ray", outcome.shift.lane
    assert_includes DevopsShift::LANES, "ray"
    refute_includes DevopsShift::LANES, "alex"
  end
end
