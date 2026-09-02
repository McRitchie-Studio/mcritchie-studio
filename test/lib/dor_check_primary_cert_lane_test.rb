# frozen_string_literal: true

# Regression for the PRIMARY repo's cert refusal in bin/dor-check —
# `suite_evidence_error`, the message every builder in every repo reads when the
# G1 cert gate refuses.
#   ruby -Itest test/lib/dor_check_primary_cert_lane_test.rb
# Also picked up by the normal `bin/rails test` sweep.
#
# THE DEFECT (2026-09-01). The refusal described the repo's obligations from
# FullSuiteGate::LANES, while the verdict it describes is computed over
# FullSuiteGate.required_lanes(repo) — which SUBTRACTS the rubocop lane for a repo
# declaring `lint_lane: none` in config/release_repos.yml, as studio-engine and
# solana-studio both do. Message and verdict read two different lists, so a
# lint-waived repo was refused with `rubocop: MISSING` for a lane the gate had
# ALREADY waived and would never grade.
#
# THREE OVER-CLAIMS, not one — which is what separates this from its sibling
# (#1150, secondary_cert_lane_state) and why it is filed as its own task:
#   1. the LANE LIST printed `rubocop: MISSING`;
#   2. the SUBJECT hard-coded "the FULL suite + FULL rubocop are not certified";
#   3. the REMEDY advertised bin/full-suite-check as "runs bin/rails test +
#      bin/rubocop IN FULL", and its REFUSES clause promised "or a lint-red tree".
# All three describe bin/full-suite-check, which SKIPS the rubocop lane for a
# declaring repo and records no rubocop evidence — so all three must follow
# required_lanes or they promise a reader evidence the writer will never produce.
#
# ITS COST is the sibling's, on the path every repo walks. Told `rubocop: MISSING`
# for studio-engine, a builder goes looking for the rubocop to run and finds none —
# not in the Gemfile, not in the gemspec, no .rubocop.yml, and `bundle exec rubocop`
# fails outright. From there it is conclude the gate is broken and escalate, or reach
# for FULL_SUITE_RUBOCOP_CMD pointed at a no-op — recording a rubocop pass for a lint
# that never ran, the manufactured evidence the waiver exists to make unnecessary
# (refused once already, 2026-08-24).
#
# THE REFUSAL COMES FIRST IN EVERY CASE BELOW. The fix is a STRING, so a test pinning
# only the wording would keep passing on a gate someone had loosened into waiving the
# SUITE lane too. The order is the guard, and the contrast case is the guard on the
# obvious wrong fix.
#
# Standalone (no Rails): FullSuiteGate is `load`ed for the fingerprints, and
# bin/dor-check is shelled with --file fixtures.

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"

load File.expand_path("../../bin/lib/full_suite_gate.rb", __dir__)

class DorCheckPrimaryCertLaneTest < Minitest::Test
  BIN = File.expand_path("../../bin/dor-check", __dir__)
  SLUG = "land-rails-security-patch"
  BRANCH = "feat/#{SLUG}"

  # The lint-waived repo under test, and an UNWAIVED one for the contrast. Both
  # waivers read the PRODUCTION config/release_repos.yml via FullSuiteGate, so these
  # exercise the shipped declaration rather than a fixture of one.
  WAIVED_REPO = "studio-engine"
  UNWAIVED_REPO = "turf-monster"

  def git!(dir, *args)
    assert system("git", "-C", dir, *args, out: File::NULL, err: File::NULL), "git #{args.join(' ')}"
  end

  def write(dir, rel, body)
    full = File.join(dir, rel)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, body)
  end

  # ONE repo's desk, standing as the PRIMARY root — …/<projects>/<repo>/.worktrees/
  # <slug>, carrying an `origin` for that repo (CertRootGuard reads the repo axis off
  # the remote) and checked out on the task branch. This is the single-repo shape:
  # dor-check roots HERE, so `suite_eval[:repo]` is this repo and the message under
  # test is the PRIMARY refusal, not a secondary sibling.
  def with_primary_desk(repo)
    Dir.mktmpdir do |raw|
      projects = File.realpath(raw)
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
      write(desk, "app/services/patch.rb", "class Patch; end\n")
      git!(desk, "add", "-A")
      git!(desk, "commit", "-qm", "patch")
      yield projects, desk
    end
  end

  # A backend task naming ONE repo, with a PR. Spec + tiers are satisfied, so the only
  # thing under test is the cert gate.
  def task_json(repo, checks)
    {
      "slug" => SLUG,
      "title" => "Land Rails Security Patch",
      "metadata" => { "devops" => {
        "kind" => "bug",
        "shape" => "backend",
        "branch" => BRANCH,
        "worktree_slug" => SLUG,
        "pr_url" => "https://github.com/x/#{repo}/pull/1",
        "repositories" => [repo],
        "acceptance" => ["patch lands in #{repo}"],
        "risk_tags" => ["security"],
        "test_plan" => ["[unit] the repo is certified"],
        "checks_run" => ["[unit] bin/rails test test/lib/dor_check_primary_cert_lane_test.rb",
                         "[integration] dor-check names the lanes the repo owes"] + checks
      } }
    }
  end

  def with_env(vars)
    saved = vars.keys.to_h { |k| [k, [ENV.key?(k), ENV[k]]] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    saved.each { |k, (had, val)| had ? ENV[k] = val : ENV.delete(k) }
  end

  # Shell bin/dor-check --file, rooted at `root`. Suite-evidence injection is forced
  # OFF so the REAL fingerprint path runs, and the PR file read is neutralized so the
  # verdict never depends on a live `gh` credential.
  def dor_check(task, root, projects)
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
        out = IO.popen(SessionEnv.neutralized, "#{BIN} --file #{path} --json 2>/dev/null", &:read)
      end
      [JSON.parse(out), $?.exitstatus]
    end
  end

  def cert_refusal(verdict)
    Array(verdict["errors"]).find { |e| e.include?("not certified green for this code") }
  end

  # THE CLAUSE UNDER TEST — everything before "Or take the FAST route", which is the
  # part of the sentence that describes `bin/full-suite-check`: the lane list, the
  # subject, and the remedy. This is the segment that must follow required_lanes.
  #
  # THE FAST-ROUTE CLAUSE IS DELIBERATELY EXCLUDED, and the split is the point rather
  # than a convenience. That clause describes `bin/fast-check`, which carries NO
  # lint-waiver branch: it omits rubocop on the GEM branch instead, and both declaring
  # repos happen to be gems today, so the two axes merely COINCIDE. Asserting the lint
  # waiver over that clause would pin bin/fast-check's behaviour to a predicate it does
  # not read, and would demand the WRONG text the day a non-gem repo declares
  # `lint_lane: none` — the exact case bin/fast-check's own comment ("NO LINT-WAIVER
  # BRANCH HERE, deliberately") reserves. Its inaccuracy for a gem is a separate defect
  # on the GEM axis, and its cost is far lower: it misdescribes a command the reader
  # simply runs, rather than telling them they OWE a cert lane that cannot be produced.
  def full_cert_clause(refusal)
    refusal.split("Or take the FAST route").first
  end

  # ── the defect: a lint-waived PRIMARY repo ──────────────────────────────────

  def test_a_lint_waived_primary_repo_is_still_refused_and_the_refusal_omits_rubocop
    # The waiver is REAL. Asserted before the property so a future edit to
    # config/release_repos.yml cannot leave this test quietly grading an UNWAIVED
    # repo and passing for the wrong reason.
    assert_equal [FullSuiteGate::TEST_LANE], FullSuiteGate.required_lanes(WAIVED_REPO),
                 "#{WAIVED_REPO} must declare lint_lane: none for this test to mean anything"

    with_primary_desk(WAIVED_REPO) do |projects, desk|
      verdict, code = dor_check(task_json(WAIVED_REPO, []), desk, projects)

      # HALF ONE — THE GATE IS UNCHANGED. A waived repo owes one FEWER lane, not
      # zero: it still owes its FULL SUITE, and lacking it must still REFUSE. This
      # half fails if the waiver is ever widened into "this repo owes nothing", or if
      # a fix to the MESSAGE reaches past it into required_lanes or eval[:ok].
      refute verdict["ready"],
             "a lint-waived repo still owes its FULL-SUITE cert — missing it must refuse"
      assert_equal 1, code

      # HALF TWO — the refusal describes only what this repo owes, in all three of
      # the places that used to over-claim.
      refusal = cert_refusal(verdict)
      refute_nil refusal, "expected a primary cert refusal: #{verdict['errors']}"
      assert_includes refusal, "#{FullSuiteGate::TEST_LANE}: MISSING",
                      "the refusal must still name the lane the repo DOES owe: #{refusal}"

      # (1) the lane list, (2) the subject, (3) the remedy's command list and its
      # REFUSES clause. One assertion covers all three: the whole sentence describes
      # bin/full-suite-check, which for this repo runs no rubocop and records none,
      # so the word must not appear in it at all.
      clause = full_cert_clause(refusal)
      refute_includes clause, FullSuiteGate::RUBOCOP_LANE,
                      "#{WAIVED_REPO} declares lint_lane: none, so bin/full-suite-check SKIPS that lane and " \
                      "records no evidence for it. Naming it sends the reader after a rubocop this repo does " \
                      "not ship, and the only way to 'satisfy' it is evidence for a lint that never ran: #{clause}"
      refute_includes clause, "lint-red",
                      "the REFUSES clause promises a lint check that will not run for this repo: #{clause}"
      assert_includes clause, "the FULL suite is not certified green",
                      "the subject must name only the suite for a waived repo: #{clause}"

      # The split above must actually have found the seam — otherwise the three
      # assertions ran against the WHOLE string and would have failed, or against a
      # truncated one and proved less than they claim.
      refute_equal refusal, clause, "expected the fast-route clause to be split off: #{refusal}"
    end
  end

  # THE CONTRAST, and the guard on the obvious wrong fix. The waiver is PER REPO and
  # DECLARED — it is not a decision to stop mentioning rubocop. A repo that has
  # declared nothing owes BOTH lanes and its refusal must still say so, so dropping
  # RUBOCOP_LANE from FullSuiteGate::LANES, or filtering the lane out of the message
  # unconditionally, fails HERE even though either would make the test above pass.
  def test_an_unwaived_primary_repo_is_still_told_its_rubocop_lane_is_missing
    assert_equal FullSuiteGate::LANES, FullSuiteGate.required_lanes(UNWAIVED_REPO),
                 "#{UNWAIVED_REPO} declares no waiver and must owe BOTH lanes"

    with_primary_desk(UNWAIVED_REPO) do |projects, desk|
      verdict, code = dor_check(task_json(UNWAIVED_REPO, []), desk, projects)

      refute verdict["ready"], "an uncertified repo must refuse"
      assert_equal 1, code
      refusal = cert_refusal(verdict)
      refute_nil refusal, "expected a primary cert refusal: #{verdict['errors']}"
      assert_includes refusal, "#{FullSuiteGate::RUBOCOP_LANE}: MISSING",
                      "an UNWAIVED repo owes its lint lane, and the refusal must still name it: #{refusal}"
      assert_includes refusal, "#{FullSuiteGate::TEST_LANE}: MISSING",
                      "and its suite lane alongside it: #{refusal}"
      assert_includes refusal, "the FULL suite + FULL rubocop are not certified green",
                      "the subject must still name both lanes for an unwaived repo: #{refusal}"
      assert_includes refusal, "`bin/rubocop`",
                      "and the remedy must still tell an unwaived repo to run it: #{refusal}"
    end
  end

  # The positive side of the same waiver, and what makes the refusal above HONEST: a
  # lint-waived PRIMARY repo carrying only its FULL-SUITE cert IS certified. So the
  # rewritten message describes a bar the repo can actually clear. Before this, the
  # refusal asked for a rubocop cert that — had the reader somehow manufactured one —
  # `ok` would not even have read.
  def test_a_lint_waived_primary_repo_is_certified_by_its_suite_cert_alone
    with_primary_desk(WAIVED_REPO) do |projects, desk|
      checks = [FullSuiteGate.evidence_line(FullSuiteGate::TEST_LANE, FullSuiteGate.fingerprint(desk),
                                            "bin/release-check green", repo: WAIVED_REPO)]

      verdict, code = dor_check(task_json(WAIVED_REPO, checks), desk, projects)

      assert_equal 0, code, "a waived repo owes only its suite cert; errors: #{verdict['errors']}"
      assert verdict["ready"], "errors: #{verdict['errors']}"
    end
  end
end
