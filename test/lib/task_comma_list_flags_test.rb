# frozen_string_literal: true

# The comma guard on bin/task's repeatable IDENTIFIER flags: the PURE half. `--repo a,b` would
# store a ONE-ELEMENT array holding the joined string, and `bin/task show` prints it like the
# correct pair until something RESOLVES the entry (Release::Conductor refuses at step 3a). The
# record LOOKS right, hence a guard. Cases driving the real binary against
# test/lib/task_cli_test.rb's stub server stay there. Here: the guard's wiring, read out of
# the script, and its ORDERING, proved against an unroutable board. Guarded set:
# lib/devops_list_flags.rb (test/lib/devops_list_flags_test.rb).
# History: task comma-repo-list-aborts-sweep.

require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"

class TaskCommaListFlagsTest < Minitest::Test
  BIN = File.expand_path("../../bin/task", __dir__)
  SOURCE = File.read(BIN)
  # A port nothing listens on. Any request the CLI actually attempts fails here
  # LOUDLY and distinguishably, which is what makes the ordering test below a
  # real experiment rather than a restatement of the refusal.
  UNROUTABLE = "http://127.0.0.1:1"
  # The connection failure a child reports once it reaches the board. Ruby's
  # net/http surfaces ECONNREFUSED through Errno; match the family, not a
  # localized message.
  NETWORK_ERROR = /Connection refused|ECONNREFUSED|Failed to open TCP/i

  def teardown
    FileUtils.remove_entry(@sandbox) if @sandbox && File.directory?(@sandbox)
  end

  def run_task(args)
    @sandbox ||= Dir.mktmpdir("task-comma-sandbox")
    env = SessionEnv.neutralized({
      "TASK_API_BASE" => UNROUTABLE,
      "AGENT_API_SECRET" => "test-secret",
      "TASK_SKIP_MARKER" => "1",
      "TASK_CLAIM_NONCE" => "inst-default"
    }.merge(TaskUsageSandboxEnv.child_env(@sandbox)))
    _out, err, status = Open3.capture3(env, RbConfig.ruby, BIN, *args)
    [err, status]
  end

  # ── the wiring (the split set itself is lib/devops_list_flags.rb) ─────────
  #
  # Guard catalog row 3.6: the LIST branch SPLITS a comma-joined identifier value
  # into entries, and only the MAP branch still refuses — --pr-url-for's repo key
  # cannot split (two repos, one url).
  def test_the_list_branch_splits_and_only_the_map_branch_refuses
    body = SOURCE[/^def parse_flags\(argv.*?\n^end$/m]
    refute_nil body, "parse_flags must be extractable to prove the split is wired"

    assert_includes body, "if COMMA_FREE_LIST_FLAGS.include?(arg)", "the LIST branch must consult the constant"
    assert_includes body, 'value.split(",")', "and split the value it reads"
    assert_includes body, "refuse_comma_list!(arg, repo,",
                    "the MAP branch must guard --pr-url-for's repo key, which cannot be split at all"
    assert_equal 1, body.scan(/refuse_comma_list!/).size, "exactly one refusal site: the map key"
  end

  # The joined and repeated spellings travel alike: both reach the (unroutable)
  # board, and neither is refused.
  def test_a_comma_joined_repo_travels_like_the_repeated_form
    [%w[--repo turf-monster,mcritchie-studio], %w[--repo turf-monster --repo mcritchie-studio],
     %w[--risk devops,release]].each do |flags|
      err, status = run_task(["create", "--title", "Two repo task", *flags])

      refute status.success?, "the board is unroutable here, so a create that reaches it still fails"
      assert_match NETWORK_ERROR, err, "#{flags.inspect} must be accepted and travel"
      refute_match(/is ONE value containing a comma/, err, "and it is never refused")
    end
  end
end
