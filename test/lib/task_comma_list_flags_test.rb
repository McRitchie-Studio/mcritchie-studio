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
# Everything here needs NO harness: the guard's SHAPE, read out of the script,
# and its ORDERING, proved against an unroutable board. config/test_health.yml
# asks for exactly that division.
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

  # ── the guarded set ────────────────────────────────────────────────────────

  # The whole design rests on this constant naming the identifier flags and
  # NOTHING else. Read it out of the script rather than restating it: a hand that
  # added `--accept` here would start refusing legitimate acceptance criteria, and
  # only this assertion would notice.
  def test_the_guard_covers_identifier_flags_and_never_prose
    literal = SOURCE[/^COMMA_FREE_LIST_FLAGS = (%w\[[^\]]*\])\.freeze$/, 1]
    refute_nil literal, "COMMA_FREE_LIST_FLAGS must be a single-line %w[] constant"
    guarded = literal.scan(/--[a-z-]+/)

    assert_equal %w[--repo --risk], guarded,
                 "only the identifier flags are guarded — a repo name and a risk tag can never " \
                 "contain a comma, and prose can"
    %w[--accept --test --checks].each do |prose|
      refute_includes guarded, prose,
                      "#{prose} is free prose; guarding it would refuse legitimate copy, which is a " \
                      "worse defect than the one this guard fixes"
    end
  end

  # A guarded flag that is not a LIST_FLAGS key guards nothing — the branch that
  # consults this constant only runs for a real list flag, so a typo would be
  # inert and silent, the exact failure mode under repair.
  def test_every_guarded_flag_is_a_real_list_flag
    list_literal = SOURCE[/^LIST_FLAGS = (\{[^\n]*\})\.freeze$/, 1]
    refute_nil list_literal, "LIST_FLAGS must be a single-line hash literal"
    known = list_literal.scan(/"(--[a-z-]+)"/).flatten
    guarded = SOURCE[/^COMMA_FREE_LIST_FLAGS = (%w\[[^\]]*\])\.freeze$/, 1].scan(/--[a-z-]+/)

    assert_equal %w[--repo --risk --accept --test --checks], known,
                 "extraction sanity — LIST_FLAGS reached real content, and only it"
    assert_empty guarded - known,
                 "a guarded flag that is not a LIST_FLAGS key is never consulted: the guard would be " \
                 "dead code and the comma would go on being accepted"
  end

  # A constant nobody reads is a dead guard. Both doors must call the refusal:
  # the LIST branch (`--repo` / `--risk`) and the MAP branch, whose repo KEY
  # Task#release_repos folds into the release identity — so a comma there reaches
  # the plan as a phantom repo by the other door.
  def test_both_parse_branches_call_the_refusal
    body = SOURCE[/^def parse_flags\(argv.*?\n^end$/m]
    refute_nil body, "parse_flags must be extractable to prove the guard is wired"

    assert_includes body, "refuse_comma_list!(arg, value) if COMMA_FREE_LIST_FLAGS.include?(arg)",
                    "the LIST branch must consult the constant"
    assert_includes body, "refuse_comma_list!(arg, repo,",
                    "the MAP branch must guard --pr-url-for's repo key, which cannot be split at all"
    assert_equal 2, body.scan(/refuse_comma_list!/).size,
                 "exactly two call sites — a third would mean a flag was guarded without a decision"
  end

  # ── ordering: the refusal precedes the network ─────────────────────────────

  def test_a_comma_joined_repo_is_refused_before_the_board_is_reached
    err, status = run_task(["create", "--title", "Two repo task", "--repo", "turf-monster,mcritchie-studio"])

    refute status.success?, "a comma-joined --repo must exit nonzero"
    assert_match(/--repo turf-monster --repo mcritchie-studio/, err,
                 "the remedy is built from the value actually typed, so it is copyable")
    refute_match NETWORK_ERROR, err,
                 "the refusal fires in parse_flags, before auth and before any request — a rejected " \
                 "line must leave no half-written record behind it"
  end

  # THE CONTROL for the case above, and the reason it is an experiment rather
  # than a restatement: the SAME command with the flag spelled correctly DOES
  # reach the board and dies on the unroutable address. Without this, "no network
  # error" would be satisfied by a CLI that never talks to anything.
  def test_the_correctly_spelled_flag_does_reach_the_board
    err, status = run_task(["create", "--title", "Two repo task", "--repo", "turf-monster",
                            "--repo", "mcritchie-studio"])

    refute status.success?, "the board is unroutable here, so a create that reaches it still fails"
    assert_match NETWORK_ERROR, err,
                 "the repeated form is accepted and travels — which is what makes the sibling test's " \
                 "silence meaningful"
    refute_match(/is ONE value containing a comma/, err, "and it is never refused")
  end

  def test_a_comma_joined_risk_is_refused_before_the_board_is_reached
    err, status = run_task(["create", "--title", "Risky joined task", "--risk", "devops,release"])

    refute status.success?
    assert_match(/--risk devops --risk release/, err)
    refute_match NETWORK_ERROR, err
  end
end
