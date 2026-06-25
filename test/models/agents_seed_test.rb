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
    assert_operator first, :>=, 9, "expected the full soul roster"
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

  test "senior reviewers carry domains + a numeric review_weight" do
    run_seed
    {
      "shannon" => "ui",
      "carl"    => "backend",
      "jasper"  => "web3",
      "steffon" => "devops",
      "alex"    => "documentation"
    }.each do |slug, domain|
      agent = Agent.find_by!(slug: slug)
      assert agent.metadata["reviewer"], "#{slug} must be a senior pool reviewer"
      assert_equal "reviewer", agent.metadata["review_role"], "#{slug} review_role"
      assert_includes Array(agent.metadata["domains"]), domain, "#{slug} owns the #{domain} domain"
      # review_weight is stored NUMERICally (not the legacy "heavy"/"light" label a
      # bare String#to_f would silently zero — see ReviewerSelector::WEIGHT_LABELS).
      # All five seniors are heavy-capable, so they share the heavy weight (2.0).
      assert_equal 2.0, agent.metadata["review_weight"], "#{slug} carries the heavy numeric weight"
    end
  end

  test "Alex is the single identity holding the documentation review seat" do
    run_seed
    docs = Agent.active.detect do |a|
      a.metadata["reviewer"] && Array(a.metadata["domains"]).include?("documentation")
    end
    assert docs, "a documentation-domain reviewer must resolve from the seed"
    assert_equal "alex", docs.slug, "Alex holds the documentation seat (no separate persona)"
    assert_equal "Lead Orchestrator", docs.title, "still the orchestrator identity"
    refute Agent.exists?(slug: "alex-docs"), "the separate alex-docs persona is retired (folded into alex)"
  end

  test "every soul has an avatar path" do
    run_seed
    Agent.find_each do |agent|
      assert agent.avatar.to_s.start_with?("/agents/"), "#{agent.slug} is missing an avatar path"
    end
  end

  # Status-line persona identity: when a session "acts as" a soul, bin/statusline
  # shows the agent's glyph + name + tint in place of the Pokémon (see Task#sync_
  # persona_identity). The seed owns each soul's emoji + an explicit color.
  test "each senior soul carries a status-line emoji and an explicit color" do
    run_seed
    %w[alex avi carl shannon jasper steffon].each do |slug|
      agent = Agent.find_by!(slug: slug)
      assert agent.emoji.present?, "#{slug} must have a status-line emoji"
      assert_match(/\A#\h{6}\z/, agent.status_color, "#{slug} must carry an explicit hex color")
    end
  end

  test "personas do not collide on the same color (distinct from the avatar fallback)" do
    run_seed
    colors = %w[jasper shannon carl steffon].map { |s| Agent.find_by!(slug: s).status_color }
    assert_equal colors.uniq, colors, "each reviewer soul gets a distinct persona tint"
  end
end
