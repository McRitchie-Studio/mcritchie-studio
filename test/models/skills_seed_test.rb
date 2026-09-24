require "test_helper"

# [unit] db/seeds/03_skills.rb assigns skills BY SOUL SLUG and SkillAssignment
# belongs_to :agent is REQUIRED, so a key naming a slug no seeded Agent carries
# raises `Agent must exist` and aborts every seed file after it — which breaks
# `db:prepare` on every fresh desk while CI, which never seeds, stays green.
class SkillsSeedTest < ActiveSupport::TestCase
  test "the skills seed completes against the seeded roster and every key names a seeded soul" do
    capture_io do
      load Rails.root.join("db/seeds/02_agents.rb").to_s
      load Rails.root.join("db/seeds/03_skills.rb").to_s
    end

    orphans = SkillAssignment.where.not(agent_slug: Agent.pluck(:slug)).distinct.pluck(:agent_slug)
    assert_empty orphans, "skill assignments name a slug no seeded Agent carries"
    assert_equal 4, SkillAssignment.where(agent_slug: "xan").count, "the orchestrator's skills land on xan"
  end
end
