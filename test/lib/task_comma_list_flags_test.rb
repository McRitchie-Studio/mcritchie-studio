# frozen_string_literal: true

# The comma guard on bin/task's repeatable IDENTIFIER flags — the PURE half.
#
# THE DEFECT. `--repo` and `--risk` are repeatable (`--repo a --repo b`), so
# `--repo a,b` stored a ONE-ELEMENT array holding the joined string. Nothing
# refused it and nothing rendered it differently — `bin/task show` prints
# `repos: a,b` for the joined entry and the correct pair alike — so the record
# read right up until something tried to RESOLVE an entry. On 2026-09-15 that was
# a live QA release sweep: Release::Conductor saw a multi-repo task naming a
# phantom repo with no PR url and refused at step 3a. Nothing was promoted,
# recorded or deployed. A second instance was typed the same night by the
# operator who had just watched the first one abort, because the record LOOKS
# right — which is the argument for a guard rather than a lesson.
#
# WHY THIS FILE EXISTS SEPARATELY. The cases that must drive the real binary
# against test/lib/task_cli_test.rb's private stub server (what actually goes on
# the wire, and the prose controls proving `--accept` survives unsplit) stay
# there, because a copy of that 261-line harness would be testing its own copy.
# Everything here needs NO harness: the guard's wiring, read out of the script,
# and its ORDERING, proved against an unroutable board. The guarded set is the
# key map, lib/devops_list_flags.rb (test/lib/devops_list_flags_test.rb).
#
#   ruby -Itest test/lib/task_comma_list_flags_test.rb

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
