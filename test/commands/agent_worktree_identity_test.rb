require "test_helper"
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "../support/desk_ledger_sink"

# A DESK COMMITS AS THE SOUL THAT CLAIMED IT (turf-monster-git-identity-wrong).
#
# THE DEFECT. bin/ship authors ITS commit from devops.built_by, but a desk commits by
# other paths too — the builder's own mid-build commits, merge-forwards, rebases — and
# those took whatever the checkout carried. turf-monster's shared .git/config carried
# `user.name = Steffon (Claude)`, so every desk's hand commits named Steffon whoever
# wrote them: 131 commits and 50 merges on origin/accepted between 2026-09-07 and
# 2026-09-16. A reviewer read that as authorship on 2026-09-15 and reasoned wrongly.
#
# This hub fixture reproduces that shape on purpose: init_hub writes "Agent Test" into
# the SHARED config, the way turf carried its default. Every commit below is a PLAIN
# `git commit`, the path bin/ship never covers, and the identity is read OUT OF GIT.
# The stamp mechanics and refusals are unit-tested in test/lib/commit_identity_test.rb;
# this file is the CLI wiring (`identity`, `new --soul`) against a real desk.
#
# THROWAWAY HUBS ONLY. Every repo lives under a tmpdir and the identity environment is
# cleared for each git read, so nothing touches a real desk or the operator's config.
class AgentWorktreeIdentityTest < ActiveSupport::TestCase
  TASK = "identity-desk".freeze

  def setup
    @projects_dir = File.realpath(Dir.mktmpdir("agent-worktree-identity"))
    @hub_dir = File.join(@projects_dir, "mcritchie-studio")
    @desk = File.join(@hub_dir, ".worktrees", TASK)
    @script = Rails.root.join("bin/agent-worktree").to_s
    @desk_ledger = DeskLedgerSink.start
    init_hub
    add_desk
  end

  def teardown
    @desk_ledger&.stop
    FileUtils.rm_rf(@projects_dir) if @projects_dir
  end

  test "[integration] identity stamps the desk's own config and a hand commit there names the soul" do
    out, err, status = agent_worktree("identity", "mcritchie-studio", TASK, "carl")

    assert status.success?, "#{out}\n#{err}"
    assert_includes out, "identity: Carl <carl@mcritchie.studio>"
    hand_commit(@desk)
    assert_equal "Carl <carl@mcritchie.studio>", git_out(@desk, "log", "-1", "--format=%an <%ae>")
    assert_equal "Carl <carl@mcritchie.studio>", git_out(@desk, "log", "-1", "--format=%cn <%ce>")
    assert_equal "Agent Test <agent-test@example.com>", author_ident(@hub_dir),
                 "the primary must keep resolving exactly as before — the stamp is the desk's alone"
    assert_equal "Agent Test", git_out(@hub_dir, "config", "--local", "--get", "user.name"),
                 "the stamp must never be written into the SHARED config"
  end

  test "[integration] identity refuses a value that is not a soul slug and stamps nothing" do
    out, err, status = agent_worktree("identity", "mcritchie-studio", TASK, "Steffon")

    refute status.success?, "a non-soul must exit non-zero:\n#{out}"
    assert_includes err, "not a soul slug"
    assert_equal "Agent Test <agent-test@example.com>", author_ident(@desk)
  end

  test "[integration] new --soul re-stamps an existing desk, and a plain new reports the stamp it finds" do
    out, err, status = agent_worktree("new", "mcritchie-studio", TASK, "--soul=shannon")
    assert status.success?, "#{out}\n#{err}"
    assert_includes out, "identity: Shannon <shannon@mcritchie.studio>",
                    "the --soul=<value> spelling must not be dropped into new's type slot"
    assert_equal "Shannon <shannon@mcritchie.studio>", author_ident(@desk)
    assert_equal "feat/#{TASK}", git_out(@desk, "rev-parse", "--abbrev-ref", "HEAD")

    out, err, status = agent_worktree("new", "mcritchie-studio", TASK, "--soul", "carl")
    assert status.success?, "#{out}\n#{err}"
    assert_equal "Carl <carl@mcritchie.studio>", author_ident(@desk),
                 "a re-claim through begin --steal re-points the desk"

    out, err, status = agent_worktree("new", "mcritchie-studio", TASK)
    assert status.success?, "#{out}\n#{err}"
    assert_includes out, "identity: Carl <carl@mcritchie.studio> (this desk's own git config)"
  end

  test "[integration] new on an unstamped desk announces it and names the stamp command" do
    out, err, status = agent_worktree("new", "mcritchie-studio", TASK)

    assert status.success?, "an unstamped desk is still a whole desk:\n#{out}\n#{err}"
    assert_includes err, "identity: UNSTAMPED"
    assert_includes err, "authored as Agent Test <agent-test@example.com>",
                    "the announcement must say what a hand commit WILL be authored as"
    assert_includes err, "bin/agent-worktree identity mcritchie-studio #{TASK} <soul>"
  end

  private

  def init_hub
    FileUtils.mkdir_p(@hub_dir)
    git_out(@hub_dir, "init", "-q")
    git_out(@hub_dir, "config", "user.email", "agent-test@example.com")
    git_out(@hub_dir, "config", "user.name", "Agent Test")
    git_out(@hub_dir, "checkout", "-q", "-b", "main")
    File.write(File.join(@hub_dir, ".gitignore"), ".env.agent-stack\n.agent-context.json\n.env.test.local\n/.worktrees/\n")
    git_out(@hub_dir, "add", ".gitignore")
    git_out(@hub_dir, "commit", "-q", "-m", "Initial commit")
    git_out(@hub_dir, "remote", "add", "origin", "git@github.com:McRitchie-Studio/mcritchie-studio.git")
    git_out(@hub_dir, "update-ref", "refs/remotes/origin/main", "HEAD")
  end

  # An already-provisioned desk: `new` over it is a RESUME, so it cuts nothing, fetches
  # nothing and allocates nothing — the path begin's --steal takes. The Redis port is
  # unroutable and the database name unused.
  def add_desk
    git_out(@hub_dir, "worktree", "add", "-q", @desk, "-b", "feat/#{TASK}")
    File.write(File.join(@desk, ".env.agent-stack"), <<~ENVFILE)
      AGENT_WORKTREE=1
      APP_SLUG=mcritchie-studio
      TASK_SLUG=#{TASK}
      APP_PORT=39998
      PORT=39998
      REDIS_URL=redis://localhost:63999/9
      DATABASE_URL=postgresql://localhost/mcritchie_studio_development_identity_probe
      TASK_RECORD_SLUG=
      TASK_URL=
      MCRITCHIE_SESSION_KEY=_studio_session_identity_desk
      LOCAL_EMAIL_CAPTURE=1
    ENVFILE
  end

  # Git with the identity ENVIRONMENT cleared, so an assertion about who a commit names
  # measures the config files and nothing a CI runner happens to export.
  def git_out(dir, *args)
    env = SessionEnv.neutralized.merge("GIT_AUTHOR_NAME" => nil, "GIT_AUTHOR_EMAIL" => nil,
                                       "GIT_COMMITTER_NAME" => nil, "GIT_COMMITTER_EMAIL" => nil)
    out, err, status = Open3.capture3(env, "git", *args, chdir: dir)
    assert status.success?, "git #{args.join(" ")} failed\n#{out}\n#{err}"
    out.strip
  end

  def hand_commit(dir)
    git_out(dir, "commit", "--allow-empty", "-q", "-m", "a hand commit, not bin/ship")
  end

  def author_ident(dir)
    git_out(dir, "var", "GIT_AUTHOR_IDENT").sub(/\s+\d+\s+[-+]\d{4}\z/, "")
  end

  def agent_worktree(*args)
    command_env = OutboundSeams.env({
      "PROJECTS_DIR" => @projects_dir,
      "AGENT_REDIS_CAPACITY_FILE" => File.join(@projects_dir, ".agents", "redis-capacity.json"),
      "AGENT_WORKTREE_LOCK" => File.join(@projects_dir, ".agents", "agent-worktree.lock"),
      "AGENT_WORKTREE_REGISTRY" => File.join(@projects_dir, ".agents", "registry.json"),
      "AGENT_WORKTREE_ORIGIN_FETCH" => "ok",
      "AGENT_WORKTREE_TASK_BIN" => OutboundSeams.stub("task-cli")
    }.merge(@desk_ledger.env))
    Open3.capture3(command_env, RbConfig.ruby, @script, *args, chdir: Rails.root.to_s)
  end
end
