# frozen_string_literal: true

# [integration] bin/agents-backup plan — the dry run an operator reads before a
# night: run as a process against two temp source folders, it lists exactly the
# files a run would copy, per source, and reads no credential (there is no `op`
# or rclone call on this path: the fake op on PATH would record one).

require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"

class AgentsBackupPlanTest < Minitest::Test
  SCRIPT = File.expand_path("../../bin/agents-backup", __dir__)

  def setup
    @tmp = Dir.mktmpdir("agents-backup-plan")
    @agents = File.join(@tmp, "agents")
    @memory = File.join(@tmp, "memory")
    { @agents => %w[epics/plan.md sessions/s.json atomic-capture/token.json harness-key.json .secret-cache/x.json tooling/a/bin/task],
      @memory => %w[MEMORY.md hub-entry-tokens.md .env] }.each do |root, rels|
      rels.each do |rel|
        FileUtils.mkdir_p(File.dirname(File.join(root, rel)))
        File.write(File.join(root, rel), "x")
      end
    end
  end

  def teardown = FileUtils.rm_rf(@tmp)

  def plan(*args)
    env = { "AGENTS_BACKUP_AGENTS_DIR" => @agents, "AGENTS_BACKUP_MEMORY_DIR" => @memory,
            "OP_SERVICE_ACCOUNT_TOKEN" => "", "PATH" => "/usr/bin:/bin:#{File.dirname(RbConfig.ruby)}" }
    Open3.capture3(env, RbConfig.ruby, SCRIPT, "plan", *args)
  end

  def test_plan_lists_the_expected_paths_and_no_secret
    out, err, status = plan
    assert status.success?, err
    listed = out.lines.map(&:strip).reject { |l| l.start_with?("#") }
    assert_equal %w[agents/epics/plan.md agents/sessions/s.json memory/MEMORY.md memory/hub-entry-tokens.md], listed
    assert_match(/# agents #{Regexp.escape(@agents)}: 2 file\(s\)/, out)
    assert_match(/# memory #{Regexp.escape(@memory)}: 2 file\(s\)/, out)
  end

  def test_plan_of_one_source_and_an_unknown_source
    out, _, status = plan("memory")
    assert status.success?
    refute_match(/agents\//, out)
    _, err, status = plan("nope")
    refute status.success?
    assert_match(/unknown source/, err)
  end
end
