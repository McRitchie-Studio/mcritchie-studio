require "test_helper"
require_relative "../support/agent_worktree_fixture"

# A DESK REACHES ITS OWN DEVELOPMENT DATABASE (close-review-leftovers-bundle, fix 1).
#
# THE DEFECT (2026-09-25, three builders): a fresh desk carried .env.agent-stack and
# .env.test.local, but dotenv loads NEITHER in the development env, so a bare
# `bin/rails db:prepare` resolved to database.yml's shared mcritchie_studio_development.
# Every write of the stack env now writes .env.development.local beside it — the file
# dotenv-rails auto-loads for the development env — whether or not a stack is booted.
class AgentWorktreeDevEnvTest < ActiveSupport::TestCase
  include AgentWorktreeFixture

  def dev_env_path = File.join(@worktree_dir, ".env.development.local")

  def stack_value(key)
    File.read(File.join(@worktree_dir, ".env.agent-stack"))[/^#{key}=(.*)$/, 1]
  end

  test "[integration] new writes the desk's development env pointer beside its stack env" do
    refute File.exist?(dev_env_path), "premise: the staged desk has no dev pointer"

    agent_worktree!("new", "mcritchie-studio", @task)

    content = File.read(dev_env_path)
    assert_includes content, "DATABASE_URL=postgresql://localhost/mcritchie_studio_development_terminal_context"
    assert_includes content, "REDIS_URL=redis://localhost:63999/9"
    assert_includes content, "PORT=39999"
    assert_includes content, "do not commit"
  end

  test "[integration] a fresh desk with no stack env gets a pointer to the DB it was allocated" do
    FileUtils.rm_f(File.join(@worktree_dir, ".env.agent-stack"))

    agent_worktree!("new", "mcritchie-studio", @task)

    allocated = stack_value("DATABASE_URL")
    assert_match %r{/mcritchie_studio_development_terminal_context\z}, allocated
    assert_includes File.read(dev_env_path), "DATABASE_URL=#{allocated}\n",
                    "the dev pointer names exactly the DB the stack env allocated"
  end
end
