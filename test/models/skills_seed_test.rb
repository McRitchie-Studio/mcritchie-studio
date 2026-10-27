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
    assert_equal 4, SkillAssignment.where(agent_slug: "mason").count, "the orchestrator's skills land on mason"
  end
end

# [integration] `bin/rails agents:seed agents:verify_skills` — the post_deploy_cmd
# of rename-loose-ends — lands the skills on a database that has none (prod on
# 2026-10-27) and moves the orchestration skill off `alex` where an older seed
# left it with the seat (the `ray` row became `alex`); the verify task fails
# loudly on either state and passes after the seed.
class AgentsSeedTaskTest < ActiveSupport::TestCase
  setup do
    require "rake"
    Rails.application.load_tasks unless Rake::Task.task_defined?("agents:seed")
    %w[agents:seed agents:verify_skills].each { |t| Rake::Task[t].reenable }
  end

  def run_task(name)
    Rake::Task[name].reenable
    capture_io { Rake::Task[name].invoke }
  end

  test "agents:seed moves ray's inherited orchestration skills from alex to mason, and verify_skills proves it" do
    capture_io do
      load Rails.root.join("db/seeds/02_agents.rb").to_s
      load Rails.root.join("db/seeds/03_skills.rb").to_s
    end
    # Prod's drift: alex holds the orchestrator's skills, mason holds none.
    SkillAssignment.where(agent_slug: %w[alex mason]).delete_all
    %w[task-orchestration rails-development api-integration monitoring].each do |skill|
      SkillAssignment.create!(agent_slug: "alex", skill_slug: skill)
    end

    error = assert_raises(SystemExit) { run_task("agents:verify_skills") }
    refute error.success?, "the drifted state fails the verify"

    SkillAssignment.delete_all
    assert_raises(SystemExit) { run_task("agents:verify_skills") }
    SkillAssignment.create!(agent_slug: "alex", skill_slug: "task-orchestration")

    run_task("agents:seed")

    assert_equal %w[api-integration monitoring rails-development task-orchestration],
                 SkillAssignment.where(agent_slug: "mason").pluck(:skill_slug).sort
    alex = SkillAssignment.where(agent_slug: "alex").pluck(:skill_slug)
    assert_includes alex, "brand-voice"
    refute_includes alex, "task-orchestration"

    out, = run_task("agents:verify_skills")
    assert_match(/mason .*task-orchestration/, out)
  end
end
