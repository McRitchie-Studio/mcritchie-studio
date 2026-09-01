# frozen_string_literal: true

# Regression for the MULTI-REPO half of the G1 cert gate — bin/dor-check +
# lib/cert_evidence.rb + bin/lib/full_suite_gate.rb.
#   ruby -Itest test/lib/dor_check_multi_repo_cert_test.rb
# Also picked up by the normal `bin/rails test` sweep.
#
# THE DEFECT (found 2026-08-13 landing land-rails-security-patch across two repos),
# in two halves that only look like one bug together:
#
#   1. The cert evidence slot was single-value: the namespace was the LANE, so
#      certifying the SECOND repo silently erased the FIRST repo's line, and this
#      gate then called a genuinely green cert STALE. That half is asserted at the
#      unit layer (test/lib/cert_evidence_test.rb) and at the board layer
#      (test/models/task_cert_evidence_test.rb).
#   2. THIS file: dor-check re-roots to ONE worktree and grades ONE fingerprint, so
#      for a task naming N repos it inspected one and N-1 went UNGATED — while the
#      verdict read as covering the task. The verdict must now name every repo, and
#      an uncertified second repo must REFUSE.
#
# The bar these assert is the PROPERTY, not the presence of a cert: a two-repo task
# that certifies BOTH repos keeps BOTH lines and the verdict names BOTH. A test that
# checks one cert is recorded passes blind — recording one cert was never broken.
#
# Standalone (no Rails): FullSuiteGate is `load`ed for the fingerprints, and
# bin/dor-check is shelled with --file fixtures.

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"

load File.expand_path("../../bin/lib/full_suite_gate.rb", __dir__)

class DorCheckMultiRepoCertTest < Minitest::Test
  BIN = File.expand_path("../../bin/dor-check", __dir__)
  SLUG = "land-rails-security-patch"
  BRANCH = "feat/#{SLUG}"

  # ── the two-repo world ──────────────────────────────────────────────────────

  def git!(dir, *args)
    assert system("git", "-C", dir, *args, out: File::NULL, err: File::NULL), "git #{args.join(' ')}"
  end

  def write(dir, rel, body)
    full = File.join(dir, rel)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, body)
  end

  # One repo's DESK for this task: …/<projects>/<repo>/.worktrees/<slug>, carrying an
  # `origin` for that repo (CertRootGuard validates the repo axis off the remote
  # first) and checked out on the task branch. Returns its path.
  def make_desk(projects, repo, body)
    desk = File.join(projects, repo, ".worktrees", SLUG)
    FileUtils.mkdir_p(desk)
    git!(desk, "init", "-q")
    git!(desk, "config", "user.email", "t@t.co")
    git!(desk, "config", "user.name", "T")
    write(desk, "README.md", "#{repo}\n")
    git!(desk, "add", "-A")
    git!(desk, "commit", "-qm", "init")
    git!(desk, "remote", "add", "origin", "https://github.com/x/#{repo}.git")
    git!(desk, "checkout", "-q", "-b", BRANCH)
    write(desk, "app/services/patch.rb", body)
    git!(desk, "add", "-A")
    git!(desk, "commit", "-qm", "patch")
    desk
  end

  # The world a genuine two-repo task creates: a desk per repo, both on the task's
  # branch, under one projects root. Yields [projects, hub_desk, turf_desk].
  def with_two_repo_world
    Dir.mktmpdir do |raw|
      projects = File.realpath(raw)
      hub = make_desk(projects, "mcritchie-studio", "class HubPatch; end\n")
      turf = make_desk(projects, "turf-monster", "class TurfPatch; end\n")
      yield projects, hub, turf
    end
  end

  def with_env(vars)
    saved = vars.keys.to_h { |k| [k, [ENV.key?(k), ENV[k]]] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    saved.each { |k, (had, val)| had ? ENV[k] = val : ENV.delete(k) }
  end

  # A backend task naming TWO repos, with a PR in each (devops.pr_urls is the
  # per-repo PR register — the coverage layer that was already multi-repo aware while
  # the cert layer was not). Spec + tiers are all satisfied, so the only thing under
  # test is the cert gate.
  def task_json(checks)
    {
      "slug" => SLUG,
      "title" => "Land Rails Security Patch",
      "metadata" => { "devops" => {
        "kind" => "bug",
        "shape" => "backend",
        "branch" => BRANCH,
        "worktree_slug" => SLUG,
        "pr_url" => "https://github.com/x/mcritchie-studio/pull/1",
        "pr_urls" => { "turf-monster" => "https://github.com/x/turf-monster/pull/305" },
        "repositories" => %w[mcritchie-studio turf-monster],
        "acceptance" => ["patch lands in both repos"],
        "risk_tags" => ["security"],
        "test_plan" => ["[unit] both repos certified"],
        "checks_run" => ["[unit] bin/rails test test/lib/dor_check_multi_repo_cert_test.rb",
                         "[integration] dor-check names every repo"] + checks
      } }
    }
  end

  # A FULL cert (suite + rubocop) for one repo's tree, scoped to that repo.
  def full_cert(repo, fingerprint)
    [FullSuiteGate.evidence_line(FullSuiteGate::TEST_LANE, fingerprint, "bin/rails test green", repo: repo),
     FullSuiteGate.evidence_line(FullSuiteGate::RUBOCOP_LANE, fingerprint, "bin/rubocop clean", repo: repo)]
  end

  # Shell bin/dor-check --file, rooted at `root`, in the two-repo world at
  # `projects`. The suite-evidence injection is forced OFF so the REAL fingerprint
  # path runs, and the PR file read is neutralized so the verdict never depends on a
  # live `gh` credential.
  def dor_check(task, root, projects, *args)
    Dir.mktmpdir do |d|
      path = File.join(d, "task.json")
      File.write(path, JSON.generate(task))
      env = {
        "DOR_CHECK_DIFF_ROOT" => root,
        "DOR_CHECK_PROJECTS_DIR" => projects,
        "DOR_CHECK_SUITE_EVIDENCE" => nil,
        "DOR_CHECK_CHANGED_FILES" => nil,
        "DOR_CHECK_DIFF_BASE" => nil,
        "DOR_CHECK_PR_FILES" => "",
        "DOR_CHECK_CI_STATUS" => "green"
      }
      out = nil
      with_env(env) do
        out = IO.popen(SessionEnv.neutralized, "#{BIN} --file #{path} --json #{args.join(' ')} 2>/dev/null", &:read)
      end
      [JSON.parse(out), $?.exitstatus]
    end
  end

  def repos_named(verdict)
    Array(verdict.dig("full_suite", "repos")).map { |entry| entry["repo"] }
  end

  # ── [integration] the property: BOTH repos certified → BOTH named, ready ─────

  def test_a_two_repo_task_certified_in_both_repos_is_ready_and_names_both
    with_two_repo_world do |projects, hub, turf|
      checks = full_cert("mcritchie-studio", FullSuiteGate.fingerprint(hub)) +
               full_cert("turf-monster", FullSuiteGate.fingerprint(turf))

      verdict, code = dor_check(task_json(checks), hub, projects)

      assert_equal 0, code, "both repos are certified; errors: #{verdict['errors']}"
      assert verdict["ready"], "expected ready=true, got errors: #{verdict['errors']}"
      assert_equal %w[mcritchie-studio turf-monster], repos_named(verdict).sort,
                   "the verdict must NAME every repo it graded — one verdict that merely LOOKS " \
                   "like it covers the task is the defect"
      assert(Array(verdict.dig("full_suite", "repos")).all? { |entry| entry["ok"] },
             "every named repo must be certified: #{verdict.dig('full_suite', 'repos')}")
    end
  end

  # ── [integration] THE MUTATION: certify in the natural (root-first) order ────
  #
  # This is what the PRE-FIX writer produced. Certifying the hub and then the turf
  # left ONE line in the single-value slot — the second write having destroyed the
  # first — so the hub's cert is simply absent. The gate must refuse and say WHICH
  # repo is ungated; before this fix it read the one surviving line, graded the one
  # tree it stood in, and passed.

  def test_the_second_cert_having_erased_the_first_is_caught_and_named
    with_two_repo_world do |projects, hub, turf|
      # The single surviving line, exactly as the old single-slot write left it.
      checks = full_cert("turf-monster", FullSuiteGate.fingerprint(turf))

      verdict, code = dor_check(task_json(checks), hub, projects)

      refute verdict["ready"], "a task whose hub cert was destroyed must NOT be ready"
      assert_equal 1, code
      assert repos_named(verdict).include?("mcritchie-studio"),
             "the verdict must still name the repo it graded"
      assert(verdict["errors"].any? { |e| e.include?("mcritchie-studio") },
             "the refusal must name the repo whose cert is missing: #{verdict['errors']}")
    end
  end

  def test_an_uncertified_second_repo_refuses_and_names_it
    with_two_repo_world do |projects, hub, turf|
      # The hub is certified; turf — a repo this task NAMES and has a PR in — is not.
      # Pre-fix this passed: the gate graded the tree it stood in and never looked.
      checks = full_cert("mcritchie-studio", FullSuiteGate.fingerprint(hub))

      verdict, code = dor_check(task_json(checks), hub, projects)

      refute verdict["ready"], "an UNCERTIFIED second repo must refuse — it is not gated otherwise"
      assert_equal 1, code
      assert_equal %w[mcritchie-studio turf-monster], repos_named(verdict).sort
      turf_entry = Array(verdict.dig("full_suite", "repos")).find { |e| e["repo"] == "turf-monster" }
      refute turf_entry["ok"], "turf-monster must be reported NOT certified"
      assert(verdict["errors"].any? { |e| e.include?("turf-monster") && e.include?("bin/full-suite-check") },
             "the refusal must name the repo AND how to certify it: #{verdict['errors']}")
      # The OTHER half of the 2026-09-01 separation: when a repo carries no evidence in
      # ANY lane, "NOTHING is recorded" is the true sentence and must survive. The fix
      # to the fast-cert case widened the read to EVIDENCE_LANES; it must not have
      # widened it to the point where an empty read prints an empty list instead.
      assert(verdict["errors"].any? { |e| e.include?("turf-monster") && e.include?("NOTHING is recorded") },
             "no evidence in any lane must still read as NOTHING recorded: #{verdict['errors']}")
      assert_equal turf, turf_entry["fingerprint_root"],
                   "the second repo must be graded against ITS OWN tree, not the one we stand in"
      refute_equal turf_entry["fingerprint"], verdict.dig("full_suite", "fingerprint"),
                   "two repos cannot share a fingerprint — that would mean one tree was graded twice"
    end
  end

  def test_a_stale_cert_in_the_second_repo_refuses
    with_two_repo_world do |projects, hub, turf|
      stale = "a" * 40
      checks = full_cert("mcritchie-studio", FullSuiteGate.fingerprint(hub)) +
               full_cert("turf-monster", stale)

      verdict, code = dor_check(task_json(checks), hub, projects)

      refute verdict["ready"], "a STALE cert in the second repo must refuse"
      assert_equal 1, code
      assert(verdict["errors"].any? { |e| e.include?("turf-monster") && e.include?(stale[0, 12]) },
             "the refusal must report the delta it was certified FOR: #{verdict['errors']}")
    end
  end

  # ── [integration] A FAST CERT IN THE SECONDARY REPO: refused, AND named ─────
  #
  # THE DEFECT (2026-09-01, raised off /tasks/port-script-comment-guard): the refusal
  # clause was built from FullSuiteGate::LANES alone, so it announced "and NOTHING is
  # recorded for it" while a fast-cert sat recorded at the EXACT fingerprint the same
  # sentence had just printed. Literally true of the graded lanes; false in the
  # English a reader acts on. Measured cost, same day: two bin/fast-check runs against
  # a repo whose fast cert was already recorded and whose CI was already green.
  #
  # BOTH HALVES ARE THE TEST, and the first one is why this file is the right home:
  # the fix is a STRING, so a test that pinned only the new wording would keep passing
  # on a gate someone had "helpfully" loosened by adding FAST_LANE to LANES. So this
  # asserts the REFUSAL first — with the CI forced GREEN, which is the state under
  # which a fast cert IS sufficient for the PRIMARY repo — and only then that the
  # refusal names what it is rejecting.

  def test_a_fast_cert_in_the_second_repo_still_refuses_and_the_refusal_names_it
    with_two_repo_world do |projects, hub, turf|
      turf_fp = FullSuiteGate.fingerprint(turf)
      # turf has a FRESH fast-cert for this exact code and nothing else. The harness
      # already forces DOR_CHECK_CI_STATUS=green, so the one pairing that makes a fast
      # cert sufficient for the PRIMARY repo is in force here too.
      checks = full_cert("mcritchie-studio", FullSuiteGate.fingerprint(hub)) +
               [FullSuiteGate.evidence_line(FullSuiteGate::FAST_LANE, turf_fp,
                                            "mapped+spine tests + scoped rubocop", repo: "turf-monster")]

      verdict, code = dor_check(task_json(checks), hub, projects)

      # HALF ONE — the gate is unchanged. A secondary repo's bar is the FULL cert, and
      # no CI state may reach past that. This half fails if FAST_LANE is ever folded
      # into FullSuiteGate::LANES.
      refute verdict["ready"], "a SECONDARY repo carrying only a fast cert must still refuse, green CI or not"
      assert_equal 1, code
      turf_entry = Array(verdict.dig("full_suite", "repos")).find { |e| e["repo"] == "turf-monster" }
      refute turf_entry["ok"], "the fast lane must not count toward a secondary repo's ok: #{turf_entry}"

      # HALF TWO — the refusal names the evidence it is rejecting, at its fingerprint.
      refusal = Array(verdict["errors"]).find { |e| e.include?("cert gate:") && e.include?("turf-monster") }
      refute_nil refusal, "expected a cert-gate refusal naming turf-monster: #{verdict['errors']}"
      refute_includes refusal, "NOTHING is recorded",
                      "a fast-cert IS recorded at @#{turf_fp[0, 12]} — claiming nothing is recorded is what " \
                      "sent a builder to run bin/fast-check twice against an already-certified tree"
      assert_includes refusal, FullSuiteGate::FAST_LANE,
                      "the refusal must NAME the lane whose evidence it is rejecting: #{refusal}"
      assert_includes refusal, "@#{turf_fp[0, 12]}",
                      "the refusal must name the FINGERPRINT the fast cert is recorded at: #{refusal}"
      assert_includes refusal, "bin/fast-check cannot clear this",
                      "and say WHY — the reason is the half that stops the wasted run. Told only that the " \
                      "fast cert does not count, a reader goes hunting for a threshold to nudge, and there " \
                      "is none: #{refusal}"
      assert_includes refusal, "bin/full-suite-check",
                      "and still say what WOULD satisfy it: #{refusal}"
    end
  end

  # The other side of the same clause: a fast cert recorded for OLDER code must not be
  # reported as if it were for this code. The trap is one step later but identical —
  # "re-run bin/fast-check" is the wrong conclusion from either freshness state,
  # because re-running it produces a FRESH fast cert that still cannot satisfy a
  # secondary repo.

  def test_a_stale_fast_cert_in_the_second_repo_is_named_as_stale_not_as_nothing
    with_two_repo_world do |projects, hub, _turf|
      stale = "b" * 40
      checks = full_cert("mcritchie-studio", FullSuiteGate.fingerprint(hub)) +
               [FullSuiteGate.evidence_line(FullSuiteGate::FAST_LANE, stale, "mapped+spine", repo: "turf-monster")]

      verdict, code = dor_check(task_json(checks), hub, projects)

      refute verdict["ready"], "a stale fast cert certifies nothing — still refuse"
      assert_equal 1, code
      refusal = Array(verdict["errors"]).find { |e| e.include?("cert gate:") && e.include?("turf-monster") }
      refute_nil refusal, "expected a cert-gate refusal naming turf-monster: #{verdict['errors']}"
      refute_includes refusal, "NOTHING is recorded", "a fast-cert line IS recorded, for older code: #{refusal}"
      assert_includes refusal, "@#{stale[0, 12]}",
                      "the refusal must report the fingerprint that evidence was taken at: #{refusal}"
      assert_includes refusal, "bin/fast-check cannot clear this",
                      "the reason must fire for a STALE fast cert too — re-running it produces a FRESH one " \
                      "that still cannot satisfy a secondary repo: #{refusal}"
    end
  end

  # ── [integration] the SINGLE-repo path is untouched ──────────────────────────

  def test_a_single_repo_task_still_takes_the_one_verdict_path
    with_two_repo_world do |projects, hub, _turf|
      task = task_json(full_cert("mcritchie-studio", FullSuiteGate.fingerprint(hub)))
      task["metadata"]["devops"]["repositories"] = ["mcritchie-studio"]
      task["metadata"]["devops"].delete("pr_urls")

      verdict, code = dor_check(task, hub, projects)

      assert_equal 0, code, "errors: #{verdict['errors']}"
      assert verdict["ready"]
      assert_equal ["mcritchie-studio"], repos_named(verdict),
                   "one repo owed a cert, so exactly one verdict — no second tree is hunted for"
    end
  end

  # A repo a task NAMES but has no PR in is deliberately NOT gated — that is the
  # gem-release shape, where a gem task names its CONSUMER repos so the gates can
  # reason the gem owes the PR while the consumers do not. Forbidding that shape was
  # tried and refuted (it breaks Task#pr_bearing_repositories / Release::SweepPlan),
  # so the gate says so out loud instead of silently implying coverage.
  def test_a_declared_repo_with_no_pr_is_not_gated_but_is_named_out_loud
    with_two_repo_world do |projects, hub, _turf|
      task = task_json(full_cert("mcritchie-studio", FullSuiteGate.fingerprint(hub)))
      task["metadata"]["devops"].delete("pr_urls")

      verdict, code = dor_check(task, hub, projects)

      assert_equal 0, code, "a consumer repo with no PR must not refuse: #{verdict['errors']}"
      assert verdict["ready"]
      assert(verdict["suggestions"].any? { |s| s.include?("turf-monster") },
             "an ungated declared repo must be stated, never left silent: #{verdict['suggestions']}")
    end
  end

  # ── [integration] a repo whose code cannot be seen fails CLOSED ──────────────

  def test_a_named_repo_with_no_tree_on_this_machine_refuses
    with_two_repo_world do |projects, hub, turf|
      checks = full_cert("mcritchie-studio", FullSuiteGate.fingerprint(hub)) +
               full_cert("turf-monster", FullSuiteGate.fingerprint(turf))
      # The second repo's desk is gone (reclaimed) and it has no primary checkout
      # here: its code cannot be seen, so its cert cannot be graded.
      FileUtils.rm_rf(File.join(projects, "turf-monster"))

      verdict, code = dor_check(task_json(checks), hub, projects)

      refute verdict["ready"], "a repo whose tree cannot be found must fail CLOSED, never be skipped"
      assert_equal 1, code
      assert(verdict["errors"].any? { |e| e.include?("turf-monster") && e.include?("UNGATED") },
             "the refusal must name the repo it could not grade: #{verdict['errors']}")
    end
  end
end
