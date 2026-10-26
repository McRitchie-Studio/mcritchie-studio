require "test_helper"

# [unit] The orchestrator seat is `mason`; `mason` is its RETIRED slug and resolves
# to it for one release (Task::SOUL_ALIASES). The alias is READ-ONLY: every
# writer that stamps a soul stamps the canonical slug, so the record never
# carries `alex` again after RenameAlexSoulToXan repointed it.
class SoulAliasTest < ActiveSupport::TestCase
  test "the roster carries alex and neither retired slug" do
    assert_includes Task::SOUL_ROSTER, "alex"
    refute_includes Task::SOUL_ROSTER, "alex", "the retired slug is an alias, not a roster entry"
    refute_includes Task::SOUL_ROSTER, "xan", "the retired slug is an alias, not a roster entry"
    assert_equal({ "alex" => "ray", "xan" => "ray" }, Task::SOUL_ALIASES, "chain-flattened: alex never lands on xan")
  end

  test "canonical_soul maps the retired slug and passes every other value through" do
    assert_equal "alex", Task.canonical_soul("alex")
    assert_equal "alex", Task.canonical_soul(" alex ")
    assert_equal "alex", Task.canonical_soul("xan")
    assert_equal "alex", Task.canonical_soul("alex")
    assert_equal "carl", Task.canonical_soul("carl")
    assert_equal "", Task.canonical_soul(nil)
    assert_equal "stefon", Task.canonical_soul("stefon"), "a typo is not an alias — it still fails .soul?"
  end

  test "soul? recognises the seat under both slugs and nothing that is neither" do
    assert Task.soul?("alex")
    assert Task.soul?("alex"), "the retired slug still names a soul while the alias stands"
    assert Task.soul?("xan"), "so does the slug ray-slug-rename retired"
    refute Task.soul?("alex-docs"), "a slug retired without an alias stays unknown"
    refute Task.soul?("stefon")
  end

  test "a build claim made as alex stamps the builder as alex" do
    task = Task.create!(title: "alias stamp sample", stage: "designed",
                        metadata: { "devops" => { "shape" => "backend" } })
    Current.task_event_actor = "alex"
    task.update!(stage: "building")

    devops = task.reload.devops
    assert_equal "alex", devops["built_by"], "the stamp is canonical, never the retired slug"
    assert_equal %w[alex], devops["builders"]
  ensure
    Current.task_event_actor = nil
  end

  test "an author set stamped under alex reads as alex and dedupes against a alex claim" do
    task = Task.create!(title: "alias dedupe sample", stage: "designed",
                        metadata: { "devops" => { "shape" => "backend" } })
    # A row exactly as a database the migration has not reached holds it.
    task.update_columns(metadata: { "devops" => { "shape" => "backend", "built_by" => "alex", "builders" => ["alex"] } })

    assert_equal "alex", task.reload.devops_built_by
    assert_equal %w[alex], task.devops_builders

    Current.task_event_actor = "alex"
    task.update!(stage: "building")
    assert_equal %w[alex], task.reload.devops["builders"], "alex and alex are ONE author, not two"
  ensure
    Current.task_event_actor = nil
  end

  test "an activity attributed to alex lands on alex; an unknown soul still drops to nil" do
    assert_equal "alex", AgentActivity.normalize_agent_value("alex")
    assert_equal "alex", AgentActivity.normalize_agent_value("RAY")
    assert_nil AgentActivity.normalize_agent_value("stefon")
    assert_includes AgentActivity::SOULS, "alex"
    refute_includes AgentActivity::SOULS, "alex"
  end

  test "a grade posted under the retired slug is stored under alex" do
    span = AgentActivity.create!(session_id: "alias-grade", category: "Explore", reason_slug: "read the seat",
                                 opened_at: Time.current, closed_at: Time.current, outcome_slug: "done")
    grade = ActionGrade.create!(agent_activity: span, grader: "mason", disposition: "good", slug: "lands on mason")

    assert_equal ActionGrade::MASON, grade.reload.grader
    assert grade.mason?
    assert grade.mason?, "the retired predicate answers the same question for one release"
    assert_equal [grade.id], ActionGrade.by_grader("mason").pluck(:id), "the scope reads through the alias too"
  end

  test "the devops shift lane typed as alex is the alex lane" do
    outcome = DevopsShift.acquire(lane: "alex", session: "sess-alias", nonce: "n1")
    assert outcome.acquired
    assert_equal "alex", outcome.shift.lane
    assert_includes DevopsShift::LANES, "alex"
    refute_includes DevopsShift::LANES, "alex"
  end
end
