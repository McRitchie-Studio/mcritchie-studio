require "test_helper"

class Release::BuilderPolicyTest < ActiveSupport::TestCase
  setup do
    Release::BuilderPolicy.reload!
  end

  test "config file exists at the documented path" do
    assert File.exist?(Release::BuilderPolicy::CONFIG_PATH)
  end

  test "auto qa allows one reviewed task in one repo without blocked risk tags" do
    task = reviewed_task("clean", repos: ["mcritchie-studio"])
    decision = Release::BuilderPolicy.evaluate([task])

    assert decision.auto_qa?
    assert_equal "auto_qa", decision.action
    assert_equal [task.slug], decision.task_slugs
    assert_equal ["mcritchie-studio"], decision.repositories
    assert_equal [], decision.risk_tags
  end

  test "propose is required when no reviewed tasks are supplied" do
    decision = Release::BuilderPolicy.evaluate([])

    assert decision.propose?
    assert_match(/no reviewed tasks supplied/, decision.reason)
  end

  test "propose is required for more than one task" do
    first = reviewed_task("first", repos: ["mcritchie-studio"])
    second = reviewed_task("second", repos: ["mcritchie-studio"])
    decision = Release::BuilderPolicy.evaluate([first, second])

    assert decision.propose?
    assert_match(/task count 2 exceeds 1/, decision.reason)
  end

  test "propose is required for more than one repo" do
    task = reviewed_task("cross", repos: ["mcritchie-studio", "turf-monster"])
    decision = Release::BuilderPolicy.evaluate([task])

    assert decision.propose?
    assert_match(/repo count 2 exceeds 1/, decision.reason)
  end

  test "propose is required for blocked risk tags" do
    task = reviewed_task("risky", repos: ["mcritchie-studio"], risks: ["Payment"])
    decision = Release::BuilderPolicy.evaluate([task])

    assert decision.propose?
    assert_match(/blocked risk tags: payment/, decision.reason)
  end

  test "production ship remains operator gated" do
    decision = Release::BuilderPolicy.evaluate([reviewed_task("ship", repos: ["mcritchie-studio"])])

    assert decision.operator_gated_ship?
    assert_equal true, decision.to_h.fetch("operator_gated_ship")
  end

  test "hash inputs are supported for pure callers" do
    decision = Release::BuilderPolicy.evaluate([
      {
        slug: "hash-task",
        metadata: {
          devops: {
            repositories: "mcritchie-studio, mcritchie-studio",
            risk_tags: "docs\ncopy"
          }
        }
      }
    ])

    assert decision.auto_qa?
    assert_equal ["hash-task"], decision.task_slugs
    assert_equal ["mcritchie-studio"], decision.repositories
    assert_equal %w[copy docs], decision.risk_tags
  end

  test "conductor exposes the reviewed queue policy decision" do
    reviewed = reviewed_task("queued", repos: ["mcritchie-studio"])
    Task.create!(title: "designed queue outsider")

    decision = Release::Conductor.builder_policy_decision

    assert decision.auto_qa?
    assert_equal [reviewed.slug], decision.task_slugs
  end

  private

  def reviewed_task(label, repos:, risks: [])
    Task.create!(
      title: "policy #{label} demo task",
      stage: "reviewed",
      metadata: { "devops" => { "shape" => "backend", "repositories" => repos, "risk_tags" => risks } }
    )
  end
end
