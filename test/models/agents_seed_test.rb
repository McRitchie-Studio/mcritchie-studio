require "test_helper"

# Exercises db/seeds/02_agents.rb directly: it runs on every deploy
# (release → QA/prod), so it must be idempotent and must carry the Deploy-flow
# redesign roles + the metadata the ReviewerSelector reads (see
# docs/agents/system/devops-cycle-design.md §1.2).
class AgentsSeedTest < ActiveSupport::TestCase
  SEED = Rails.root.join("db/seeds/02_agents.rb").to_s

  def run_seed
    capture_io { load SEED }
  end

  test "seeds the full roster and is idempotent" do
    run_seed
    first = Agent.count
    assert_operator first, :>=, 10, "expected the full soul roster"
    run_seed
    assert_equal first, Agent.count, "re-running the seed must not create duplicates"
  end

  test "re-seeding writes nothing (no churn on every deploy)" do
    run_seed
    checkpoint = Agent.maximum(:updated_at)
    travel 2.seconds do
      run_seed
    end
    assert_equal checkpoint, Agent.maximum(:updated_at),
      "an unchanged re-seed must not bump any updated_at"
  end

  test "Steffon is the Platform Engineer and QA owner" do
    run_seed
    steffon = Agent.find_by!(slug: "steffon")
    assert_equal "Platform Engineer", steffon.title
    assert steffon.metadata["reviewer"], "Steffon reviews DevOps/Platform PRs"
    assert steffon.metadata["qa_owner"], "Steffon owns the QA tier + QA deploy"
    assert_includes Array(steffon.metadata["domains"]), "devops"
  end

  test "Avi is the review delegator + ship gate, not a pool reviewer" do
    run_seed
    avi = Agent.find_by!(slug: "avi")
    assert_equal "delegator", avi.metadata["review_role"]
    assert avi.metadata["ship_gate"], "Avi owns the ship gate"
    refute avi.metadata["reviewer"], "Avi delegates review; he is not one of the two seniors"
  end

  test "senior reviewers carry domains + heavy review_weight" do
    run_seed
    {
      "shannon"   => "ui",
      "carl"      => "backend",
      "jasper"    => "web3",
      "steffon"   => "devops",
      "alex-docs" => "documentation"
    }.each do |slug, domain|
      agent = Agent.find_by!(slug: slug)
      assert agent.metadata["reviewer"], "#{slug} must be a senior pool reviewer"
      assert_equal "reviewer", agent.metadata["review_role"], "#{slug} review_role"
      assert_includes Array(agent.metadata["domains"]), domain, "#{slug} owns the #{domain} domain"
      assert_equal "heavy", agent.metadata["review_weight"], "#{slug} is heavy-capable"
    end
  end

  test "the docs-reviewer persona resolves, distinct from the orchestrator seat" do
    run_seed
    docs = Agent.active.detect do |a|
      a.metadata["reviewer"] && Array(a.metadata["domains"]).include?("documentation")
    end
    assert docs, "a documentation-domain reviewer must resolve from the seed"
    assert_equal "alex-docs", docs.slug
    assert_equal "alex", docs.metadata["persona_of"], "docs persona links back to Alex"

    orchestrator = Agent.find_by!(slug: "alex")
    assert_equal "orchestrator", orchestrator.metadata["review_role"]
    refute orchestrator.metadata["reviewer"], "the orchestrator seat is not itself a reviewer"
    refute_equal docs.slug, orchestrator.slug, "docs reviewer is a distinct seat"
  end

  test "every soul has an avatar path" do
    run_seed
    Agent.find_each do |agent|
      assert agent.avatar.to_s.start_with?("/agents/"), "#{agent.slug} is missing an avatar path"
    end
  end
end
