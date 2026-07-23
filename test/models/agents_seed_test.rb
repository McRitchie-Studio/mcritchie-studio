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

  test "Steffon is the Platform Engineer — ship gate, no longer the QA owner" do
    run_seed
    steffon = Agent.find_by!(slug: "steffon")
    assert_equal "Platform Engineer", steffon.title
    assert steffon.metadata["reviewer"], "Steffon is the DevOps/Platform light reviewer"
    assert steffon.metadata["ship_gate"], "Steffon owns production-deploy (the ship gate)"
    refute steffon.metadata["qa_owner"], "after the reslot the QA-owner exclusion keys on Avi, not Steffon"
    assert_includes Array(steffon.metadata["domains"]), "devops"
  end

  test "Avi is the qa-release assembler and the QA owner, not a pool reviewer" do
    run_seed
    avi = Agent.find_by!(slug: "avi")
    assert_nil avi.metadata["review_role"], "Avi no longer delegates review — Carl owns it"
    assert avi.metadata["assembler"], "Avi owns the qa-release sweep + QA"
    assert avi.metadata["qa_owner"], "the reviewer-select QA-owner exclusion keys on Avi (he runs qa-release + QA)"
    refute avi.metadata["ship_gate"], "Avi no longer owns the ship gate — Steffon ships"
    refute avi.metadata["reviewer"], "Avi is not one of the pool reviewers"
  end

  test "re-seeding strips a stale qa_owner left on a non-Avi row (the merge alone can't)" do
    # A pre-reslot row: Steffon still carrying the old qa_owner flag. The metadata
    # merge only ADDS/overwrites keys present in seed data, so dropping qa_owner from
    # Steffon's seed can't remove a flag already on the live row — the seed's
    # reconciliation must. Avi ends the sole qa_owner.
    run_seed
    steffon = Agent.find_by!(slug: "steffon")
    steffon.update!(metadata: steffon.metadata.merge("qa_owner" => true))
    assert steffon.reload.metadata["qa_owner"], "precondition: the stale flag is present"

    run_seed

    refute Agent.find_by!(slug: "steffon").metadata["qa_owner"], "the stale qa_owner is reconciled off Steffon"
    assert Agent.find_by!(slug: "avi").metadata["qa_owner"], "Avi remains the sole qa_owner"
  end

  test "Carl is the Lead Architect and standing primary review owner" do
    run_seed
    carl = Agent.find_by!(slug: "carl")
    assert_equal "Lead Architect", carl.title
    assert carl.metadata["reviewer"], "Carl is in the review pool"
    assert_equal "owner", carl.metadata["review_role"], "Carl owns PR review"
    assert carl.metadata["standing_primary"], "Carl is the standing primary on every PR"
    assert_includes Array(carl.metadata["domains"]), "backend"
    assert_equal 2.0, carl.metadata["review_weight"]
  end

  test "the light specialists carry domains + a numeric review_weight" do
    run_seed
    # Carl is the standing primary (tested above); the four below are the LIGHT
    # specialist pool the review draws a domain second-read from.
    {
      "shannon" => "ui",
      "jasper"  => "web3",
      "steffon" => "devops",
      "alex"    => "documentation"
    }.each do |slug, domain|
      agent = Agent.find_by!(slug: slug)
      assert agent.metadata["reviewer"], "#{slug} must be a light-pool specialist"
      assert_equal "reviewer", agent.metadata["review_role"], "#{slug} review_role"
      assert_includes Array(agent.metadata["domains"]), domain, "#{slug} owns the #{domain} domain"
      # review_weight is stored NUMERICally (not the legacy "heavy"/"light" label a
      # bare String#to_f would silently zero — see ReviewerSelector::WEIGHT_LABELS).
      # The specialists share the heavy weight (2.0) — it breaks a LIGHT-seat tie.
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
