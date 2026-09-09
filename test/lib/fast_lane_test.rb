# frozen_string_literal: true

# [unit] Pure-logic tests for bin/lib/fast_lane.rb — the skip/resume decisions
# behind the fast-lane wrappers (`bin/task begin`, `bin/ship`). The wrappers'
# orchestration is exercised end-to-end in test/lib/task_begin_test.rb and
# test/lib/ship_test.rb; THIS file pins the decisions those runs depend on.
# Run directly:
#   ruby -Itest test/lib/fast_lane_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../../bin/lib/fast_lane"
require_relative "../../bin/lib/full_suite_gate"

class FastLaneTest < Minitest::Test
  # --- derive_slug: the client-side mirror of Task#generate_slug ---------------

  def test_derive_slug_parameterizes_a_title
    assert_equal "fast-lane-begin-ship", FastLane.derive_slug("Fast Lane Begin Ship")
  end

  def test_derive_slug_collapses_punctuation_and_trims_hyphens
    assert_equal "fix-nav-bug", FastLane.derive_slug("  Fix: Nav / Bug!  ")
  end

  def test_derive_slug_of_blank_is_empty
    assert_equal "", FastLane.derive_slug(nil)
    assert_equal "", FastLane.derive_slug("   ")
  end

  # --- open_pr: the idempotent-PR probe ----------------------------------------

  def test_open_pr_returns_the_first_listed_pr
    json = JSON.generate([{ "number" => 7, "url" => "https://github.com/x/y/pull/7",
                            "isDraft" => true, "baseRefName" => "main" }])
    pr = FastLane.open_pr(json)
    assert_equal 7, pr["number"]
    assert_equal "main", pr["baseRefName"]
    assert pr["isDraft"]
  end

  def test_open_pr_is_nil_for_no_prs_or_garbage
    assert_nil FastLane.open_pr("[]")
    assert_nil FastLane.open_pr("")
    assert_nil FastLane.open_pr("not json")
    assert_nil FastLane.open_pr(JSON.generate("unexpected" => "shape"))
  end

  # --- pr_body: the task URL must LEAD the body --------------------------------

  def test_pr_body_leads_with_the_task_url
    body = FastLane.pr_body("https://mcritchie.studio/tasks/demo", ["does the thing", "  ", nil])
    lines = body.lines.map(&:chomp)
    assert_equal "https://mcritchie.studio/tasks/demo", lines.first,
                 "the review supervisor and qa-release sweep key on the task URL being line 1"
    assert_includes lines, "- does the thing"
    refute_includes lines, "- "
  end

  def test_pr_body_without_acceptance_is_just_the_url
    assert_equal "https://mcritchie.studio/tasks/demo\n",
                 FastLane.pr_body("https://mcritchie.studio/tasks/demo", [])
  end

  # --- cert_fresh?: ship's only skippable gate, fingerprint-bound --------------

  def test_cert_fresh_with_a_fresh_fast_cert
    assert FastLane.cert_fresh?(["[fast-cert@abc1234] green"], "abc1234")
  end

  def test_cert_fresh_with_a_fresh_full_pair
    checks = ["[full-suite@abc1234] tests green", "[rubocop@abc1234] lint clean"]
    assert FastLane.cert_fresh?(checks, "abc1234")
  end

  def test_cert_not_fresh_when_the_tree_moved_on
    refute FastLane.cert_fresh?(["[fast-cert@aaa1111] green"], "bbb2222"),
           "any edit changes the tree hash — a stale cert must re-arm the fast-check step"
  end

  def test_cert_not_fresh_on_a_half_full_pair
    refute FastLane.cert_fresh?(["[full-suite@abc1234] tests green"], "abc1234"),
           "the full route needs BOTH full lanes; one alone must not skip the cert"
  end

  # [unit] The push-retry decision for ship-handles-rebased-branch: a
  # non-fast-forward rejection (a rebased branch) earns a --force-with-lease
  # retry; every OTHER failure must NOT (never force over auth/network/foreign).
  def test_push_rejected_non_fast_forward_classifies_git_output
    assert FastLane.push_rejected_non_fast_forward?(
      "! [rejected]        feat/x -> feat/x (non-fast-forward)\nerror: failed to push some refs"
    ), "a real rebase rejection must be recognized"
    assert FastLane.push_rejected_non_fast_forward?("hint: Updates were rejected (fetch first)"),
           "the (fetch first) shape counts too"
    refute FastLane.push_rejected_non_fast_forward?("fatal: Authentication failed for 'origin'"),
           "an auth failure is NOT a rebase — must not be force-pushed"
    refute FastLane.push_rejected_non_fast_forward?("fatal: unable to access ... Could not resolve host"),
           "a network failure is NOT a rebase"
    refute FastLane.push_rejected_non_fast_forward?("")
    refute FastLane.push_rejected_non_fast_forward?(nil)
  end

  def test_cert_not_fresh_without_evidence_or_fingerprint
    refute FastLane.cert_fresh?([], "abc1234")
    refute FastLane.cert_fresh?(["[unit] bin/rails test test/foo_test.rb"], "abc1234")
    refute FastLane.cert_fresh?(["[fast-cert@abc1234] green"], nil),
           "no fingerprint (unfingerprintable root) must never skip the cert"
  end

  # --- handoff_command: the line `bin/task begin` prints last -------------------
  # THE HINT IS A CLAIM ABOUT WHERE A SCRIPT LIVES, and nothing checked it against
  # the filesystem until this task. These assertions are keyed on the disk, not on
  # the wording: the command the tool prints must RESOLVE to an existing executable
  # and must name the desk to run it from. The end-to-end wiring — that `bin/task
  # begin` actually prints this — is pinned in test/lib/task_begin_test.rb, because a
  # correct helper the script never calls fixes nothing.

  # The bin/ of the checkout these tests ship in — the real hub bin dir, so the
  # fallback arm is asserted against the real bin/ship rather than a fixture.
  HUB_BIN = File.expand_path("../../bin", __dir__)

  # A bare `bin/ship`, and ONLY a bare one: the lookbehind exempts any path form
  # (/Users/…/bin/ship, ./bin/ship). Same shape as the docs guard in
  # test/docs/fast_lane_hub_path_docs_test.rb.
  BARE_SHIP = %r{(?<![\w/.-])bin/ship(?![\w-])}

  # [cd-target, ship, slug] parsed out of `cd <desk> && <ship> <slug>`.
  def parse_handoff(command)
    cd, run = command.split(" && ", 2)
    refute_nil run, "the hint must join a cd and the ship invocation: #{command.inspect}"
    ship, slug = run.split(" ", 2)
    [cd.to_s.sub(/\Acd /, ""), ship, slug.to_s.strip]
  end

  def test_handoff_command_names_an_executable_ship
    Dir.mktmpdir("desk-without-ship") do |desk|
      _cd, ship, slug = parse_handoff(FastLane.handoff_command("fix-nav-bug", desk, HUB_BIN))

      assert_equal "fix-nav-bug", slug
      assert_equal ship, File.expand_path(ship),
                   "the hint must name an ABSOLUTE ship path — a relative one resolves " \
                   "only from whichever desk the reader happens to be standing in"
      assert File.executable?(ship),
             "begin would print #{ship}, which is not an executable file — the hint " \
             "names a script that does not exist"
    end
  end

  # The defect itself. A satellite desk carries no bin/ship, so the bare form the
  # hint used to print died as `nohup: bin/ship: No such file or directory`.
  def test_handoff_command_is_never_bare
    Dir.mktmpdir("desk-without-ship") do |desk|
      command = FastLane.handoff_command("fix-nav-bug", desk, HUB_BIN)
      refute_match BARE_SHIP, command,
                   "the hint printed a bare bin/ship, which resolves only from a hub desk"
    end
    # Non-vacuity: the pattern must really bite the form this test forbids.
    assert_match BARE_SHIP, "hand off with: bin/ship fix-nav-bug",
                 "BARE_SHIP does not match the bare form, so the assertion above proves nothing"
  end

  # The cwd half. bin/ship roots at the cwd's git toplevel and CertRootGuard refuses
  # a run rooted anywhere but the task's tree, so naming the script without naming the
  # desk trades one failure for its mirror image.
  def test_handoff_command_stands_in_the_desk
    Dir.mktmpdir("desk-without-ship") do |desk|
      cd, = parse_handoff(FastLane.handoff_command("fix-nav-bug", desk, HUB_BIN))
      assert_equal desk, cd, "the hint must cd to the task's desk before running ship"
    end
  end

  # A hub desk ships its own bin/, and it is fresh off `accepted` while a primary
  # routinely lags it — so the desk's own script wins when there is one.
  def test_handoff_command_prefers_the_desks_own_ship
    Dir.mktmpdir("desk-with-ship") do |desk|
      desk_ship = File.join(desk, "bin", "ship")
      FileUtils.mkdir_p(File.dirname(desk_ship))
      File.write(desk_ship, "#!/bin/sh\n")
      FileUtils.chmod("+x", desk_ship)

      _cd, ship, = parse_handoff(FastLane.handoff_command("fix-nav-bug", desk, HUB_BIN))
      assert_equal desk_ship, ship, "a desk that carries bin/ship must be handed its own"
    end
  end

  # Resolution is by EXECUTABILITY, not mere presence: a non-executable file at that
  # path cannot be run, so it must not be printed as if it could.
  def test_handoff_command_ignores_a_non_executable_desk_ship
    Dir.mktmpdir("desk-with-dud-ship") do |desk|
      dud = File.join(desk, "bin", "ship")
      FileUtils.mkdir_p(File.dirname(dud))
      File.write(dud, "not a program")
      FileUtils.chmod(0o644, dud)

      _cd, ship, = parse_handoff(FastLane.handoff_command("fix-nav-bug", desk, HUB_BIN))
      refute_equal dud, ship, "a non-executable desk ship must not be printed"
      assert File.executable?(ship), "the fallback must be a runnable script"
    end
  end
end
