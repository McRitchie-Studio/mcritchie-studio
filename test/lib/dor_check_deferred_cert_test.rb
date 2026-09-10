# frozen_string_literal: true

# THE FENCE. bin/dor-check's DEFERRED cert route — the half of
# capped-cert-blocks-the-pr that decides whether the change is a fix or a hole.
#   ruby -Itest test/lib/dor_check_deferred_cert_test.rb
# Also picked up by the normal `bin/rails test` sweep.
#
# WHAT MOVED, AND WHY THE MOVE NEEDS A FENCE. bin/fast-check runs at ship step 2 of
# 8 — before the push, before the PR, before any CI exists. So its (correct) refusal
# of a diff it cannot certify left the builder with no PR, no CI, and one remedy: a
# local full suite, MEASURED at ~30 minutes against CI's ~9 for the identical
# command. A build paid that in full on 2026-09-06.
#
# THE REPO IS turf-monster, AND THAT IS NOT DECORATION. The refusal is a SATELLITE
# condition, not a cap condition, and the fixture has to be able to tell them apart.
# config/fast_cert_spine.yml has five entries and ALL FIVE exist only in the hub
# (measured 2026-09-06: turf-monster 0 of 5, rolio 0 of 5). So the same capped diff
# splits two ways, and both halves were observed the same day:
#
#   HUB  (release-offers-retired-cert): 51 paths over the cap → mapped lane skipped →
#        the SPINE still ran → certified green, accepted against a green CI. The cap
#        cost coverage, not the PR. This path must not change, and does not.
#   SATELLITE (empty-solana-network-fails-open, turf-monster): 29 paths over the cap →
#        mapped lane skipped → spine resolves to NOTHING → zero executed tests →
#        REFUSED, and the builder paid the ~30 minutes.
#
# So the condition being fixed is "this run will execute ZERO test files, and the only
# reason is a cap we imposed" — which on today's spine means the six non-hub repos.
#
# The remedy is to let a CAPPED diff push, open its PR, and let a GREEN CI carry the
# suite — so bin/fast-check now records a fingerprint-bound "[cert-deferred@<fp>]"
# receipt and exits 2 instead of dying, and THIS file is what stops that from being
# a fail-green one rung further along than the one PR #1226 closed.
#
# DEFERRING IS NOT SKIPPING, and these tests are the sentence that means:
#
#   green CI    → the gate is satisfied (the mapped tests ran; CI is where)
#   RED CI      → REFUSED
#   NO CI       → REFUSED  ← the designed-against failure: a capped diff that pushes,
#                            gets no CI at all, and submits on nothing
#   pending CI  → REFUSED (there is NO provisional twin for a deferral, deliberately:
#                          a fast cert may be credited against a pending CI because a
#                          real local run stands underneath it; a deferral has nothing)
#   stale receipt → REFUSED even on green (the CI graded a tree that is not this one)
#
# Standalone (no Rails): FullSuiteGate is `load`ed for the fingerprint, and
# bin/dor-check is shelled with --file fixtures.

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"

load File.expand_path("../../bin/lib/full_suite_gate.rb", __dir__)

class DorCheckDeferredCertTest < Minitest::Test
  BIN = File.expand_path("../../bin/dor-check", __dir__)
  SLUG = "capped-cert-blocks-the-pr"
  BRANCH = "feat/#{SLUG}"
  # A SATELLITE, deliberately: the hub keeps a live spine under a cap and never reaches
  # this route at all. Grading the deferral against a hub fixture would test the repo
  # that does not need it.
  REPO = "turf-monster"

  # What bin/fast-check writes as the receipt's detail. Shaped like the real one so a
  # reader of a failure here sees what the board actually carries.
  DETAIL = "cert DEFERRED to GitHub CI: the mapped lane was CAPPED — 26 mapped path(s) over the " \
           "cap of 15 (widest: app/services/solana/config.rb → 24 test file(s)) — over a spine " \
           "this checkout resolves NONE of, so NO local lane could certify this tree."

  def git!(dir, *args)
    assert system("git", "-C", dir, *args, out: File::NULL, err: File::NULL), "git #{args.join(' ')}"
  end

  def write(dir, rel, body)
    full = File.join(dir, rel)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, body)
  end

  # The task's own desk — …/<projects>/<repo>/.worktrees/<slug>, carrying an `origin`
  # for the repo (CertRootGuard reads the repo axis off the remote) and checked out on
  # the task branch. dor-check roots HERE, so the cert verdict under test is the
  # PRIMARY one and the fingerprint is this tree's.
  def with_desk
    Dir.mktmpdir do |raw|
      projects = File.realpath(raw)
      desk = File.join(projects, REPO, ".worktrees", SLUG)
      FileUtils.mkdir_p(desk)
      git!(desk, "init", "-q")
      git!(desk, "config", "user.email", "t@t.co")
      git!(desk, "config", "user.name", "T")
      write(desk, "README.md", "#{REPO}\n")
      git!(desk, "add", "-A")
      git!(desk, "commit", "-qm", "init")
      git!(desk, "remote", "add", "origin", "https://github.com/x/#{REPO}.git")
      git!(desk, "checkout", "-q", "-b", BRANCH)
      # A diff wide enough to be the real case: the file measured tripping the cap.
      write(desk, "app/services/solana/config.rb", "module Solana; class Config; end; end\n")
      git!(desk, "add", "-A")
      git!(desk, "commit", "-qm", "widen")
      yield projects, desk
    end
  end

  # The receipt bin/fast-check would have written for `desk`'s CURRENT tree.
  def receipt_for(desk)
    fp = FullSuiteGate.fingerprint(desk)
    refute_nil fp, "the fixture desk must fingerprint"
    FullSuiteGate.evidence_line(FullSuiteGate::DEFER_LANE, fp, DETAIL, repo: REPO)
  end

  # A backend task naming ONE repo, with a PR. Spec, tiers and acceptance are all
  # satisfied, so the ONLY thing these tests grade is the cert route.
  def task_json(checks)
    {
      "slug" => SLUG,
      "title" => "Capped Cert Blocks The PR",
      "metadata" => { "devops" => {
        "kind" => "bug",
        "shape" => "backend",
        "branch" => BRANCH,
        "worktree_slug" => SLUG,
        "pr_url" => "https://github.com/x/#{REPO}/pull/1",
        "repositories" => [REPO],
        "acceptance" => ["a capped diff still reaches its PR"],
        "risk_tags" => ["devops"],
        "test_plan" => ["[unit] a capped cert defers to CI"],
        "checks_run" => ["[unit] bin/rails test test/lib/dor_check_deferred_cert_test.rb",
                         "[integration] the deferred route refuses a red or absent CI"] + checks
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

  # Shell bin/dor-check --file, rooted at the desk. Suite-evidence injection is forced
  # OFF so the REAL fingerprint + evidence-grading path runs — the receipt under test
  # is graded exactly as a builder's would be. Only CI is injected.
  #
  # `role:` IS A COMMAND-LINE PARAMETER AND NOT AN `extra:` KEY, and the distinction is
  # the whole reason it exists. bin/dor-check reads the role from --gate-role ONLY
  # — its `options` hash seeds the "builder" default and the --gate-role switch is the
  # only writer, and there is NO env seam anywhere for it. `extra:`, meanwhile, merges
  # into `env` above, which with_env applies to the CHILD'S ENVIRONMENT. So a role
  # handed through `extra:` is not overridden or rejected: it is never read, the child
  # silently runs the DEFAULT builder role, and
  # the run still looks exactly like the one that was asked for. The role test below
  # spent its life doing precisely that — asserting the builder role twice under a
  # comment claiming the role was the only variable — which is why it could not catch
  # the role-blind refusal that shipped beside it in the same commit (2f8973a4).
  # Sibling test/lib/dor_check_exempt_ci_test.rb passes it on the command line for the
  # same reason.
  #
  # It is passed on EVERY call, including the builder ones, deliberately. "builder" is
  # already the default, so stating it changes no behaviour — but it means the flag is
  # exercised by every test in this file, and a --gate-role that were ever renamed or
  # dropped dies here as an unknown-option error in all of them instead of degrading
  # quietly into the default in the one test that cared.
  def dor_check(task, desk, projects, ci:, role: "builder", extra: {})
    Dir.mktmpdir do |d|
      path = File.join(d, "task.json")
      File.write(path, JSON.generate(task))
      env = {
        "DOR_CHECK_DIFF_ROOT" => desk,
        "DOR_CHECK_PROJECTS_DIR" => projects,
        "DOR_CHECK_SUITE_EVIDENCE" => nil,
        "DOR_CHECK_CHANGED_FILES" => nil,
        "DOR_CHECK_DIFF_BASE" => nil,
        "DOR_CHECK_PR_FILES" => "",
        "DOR_CHECK_CI_STATUS" => ci
      }.merge(extra)
      out = nil
      with_env(env) do
        out = IO.popen(SessionEnv.neutralized,
                       "#{BIN} --file #{path} --json --gate-role #{role} 2>/dev/null", &:read)
      end
      [JSON.parse(out), $?.exitstatus]
    end
  end

  def defer_refusal(verdict)
    Array(verdict["errors"]).find { |e| e.include?("DEFERRED") || e.include?("DEFERRAL") }
  end

  # WHAT A REVIEW-ROLE RUN LOOKS LIKE FROM THE OUTSIDE. bin/dor-check emits no
  # gate_role field, so "did the role land?" has to be answered from role-DEPENDENT
  # behaviour, and this is the one that fires in every CI state: the zap check (is the
  # tree this verdict graded the commit that will merge?) is asked ONLY under
  # --gate-role review, and with no headRefOid to compare against it reports itself
  # unmade. Measured on this exact fixture across green/red/pending/unreadable —
  # present in all four review runs, absent from all four builder runs.
  #
  # Keyed on a phrase, so a reworded suggestion fails this. That direction is the safe
  # one: it can only ever cost a FALSE RED, never let a builder-role run pass itself
  # off as a review one, which is the failure actually being fenced.
  def review_role_marker?(verdict)
    Array(verdict["suggestions"]).any? { |s| s.include?("the zap check") }
  end

  # --- [integration] the route the change exists to open ---------------------------

  # ACCEPTANCE 2. A green CI satisfies G1 for a diff no local lane could certify —
  # the mapped tests DID run, on this exact tree, in the run the PR triggered anyway.
  def test_a_deferred_receipt_and_a_GREEN_ci_satisfy_the_suite_gate
    with_desk do |projects, desk|
      verdict, code = dor_check(task_json([receipt_for(desk)]), desk, projects, ci: "green")

      assert verdict["ready"], "a fresh deferral beside a GREEN CI is the whole remedy: #{verdict['errors']}"
      assert_equal 0, code
      assert_equal "deferred", verdict.dig("full_suite", "route"),
                   "it must be credited as DEFERRED, never quietly as a fast or full cert"
    end
  end

  # THE CONTROL. Strip the receipt and NOTHING else changes — same tree, same green
  # CI. Without this, every test above could be passing because green CI alone is
  # enough, which would be the hole rather than the fence.
  def test_a_GREEN_ci_with_NO_receipt_is_still_refused
    with_desk do |projects, desk|
      verdict, code = dor_check(task_json([]), desk, projects, ci: "green")

      refute verdict["ready"], "a green CI alone must never certify a diff — the receipt is what defers"
      assert_equal 1, code
      assert_nil verdict.dig("full_suite", "route")
    end
  end

  # --- [integration] ACCEPTANCE 3 — the fence -------------------------------------

  # A RED CI. The evidence the deferral pointed at came back negative; there is no
  # local run to fall back on, so the submit is refused.
  def test_a_deferred_receipt_with_a_RED_ci_refuses_the_submit
    with_desk do |projects, desk|
      verdict, code = dor_check(task_json([receipt_for(desk)]), desk, projects, ci: "red")

      refute verdict["ready"], "a deferral is not a skip — a RED CI must refuse"
      assert_equal 1, code
      refusal = defer_refusal(verdict)
      refute_nil refusal, "the refusal must name the DEFERRAL, not read as a missing cert: #{verdict['errors']}"
      assert_includes refusal, "RED"
      refute_includes refusal, "bin/fast-check #{SLUG})",
                      "re-running the cert re-defers — offering it as the remedy is a loop"
    end
  end

  # THE ONE THIS WHOLE FILE IS FOR. A capped diff that pushes, gets NO CI at all, and
  # would otherwise submit on nothing — recreating PR #1226's fail-green one rung
  # along. There is no evidence anywhere for this diff, and the gate says so.
  def test_a_deferred_receipt_with_NO_ci_at_all_refuses_the_submit
    with_desk do |projects, desk|
      verdict, code = dor_check(task_json([receipt_for(desk)]), desk, projects, ci: "none")

      refute verdict["ready"],
             "a deferral with NO CI has NO evidence anywhere — submitting on it is the fail-green this closes"
      assert_equal 1, code
      refusal = defer_refusal(verdict)
      refute_nil refusal, "expected a deferral refusal: #{verdict['errors']}"
      assert_includes refusal, "NO CI on this PR"
      assert_includes refusal, "NO evidence"
    end
  end

  # NO PROVISIONAL TWIN, and the asymmetry is deliberate. Submit-side, a fresh FAST
  # cert IS credited against a pending CI — because a real local run stands underneath
  # it. A deferral has nothing underneath it, so the same CI state must refuse.
  def test_a_deferred_receipt_is_never_credited_provisionally_on_a_pending_ci
    with_desk do |projects, desk|
      verdict, code = dor_check(task_json([receipt_for(desk)]), desk, projects, ci: "pending")

      refute verdict["ready"], "the fast lane's provisional credit must NOT extend to a deferral"
      assert_equal 1, code
      refute_equal "fast-provisional", verdict.dig("full_suite", "route")
      assert_includes defer_refusal(verdict).to_s, "still RUNNING"
    end
  end

  # A RECEIPT FOR A DIFFERENT TREE IS NOT A RECEIPT FOR THIS ONE. Edit after
  # deferring and the CI run the receipt points at graded code that is not what
  # would merge — the same staleness rule every other lane obeys, on the lane whose
  # whole content is a promise about a tree.
  def test_a_STALE_deferred_receipt_refuses_even_on_a_green_ci
    with_desk do |projects, desk|
      stale = receipt_for(desk)
      write(desk, "app/services/solana/config.rb", "module Solana; class Config; VERSION = 2; end; end\n")

      verdict, code = dor_check(task_json([stale]), desk, projects, ci: "green")

      refute verdict["ready"], "the code moved after the deferral — CI graded another tree"
      assert_equal 1, code
      refusal = defer_refusal(verdict)
      refute_nil refusal, "expected a STALE-deferral refusal: #{verdict['errors']}"
      assert_includes refusal, "STALE"
      assert_includes refusal, "bin/fast-check #{SLUG}",
                      "here re-running the cert IS the remedy — it re-defers against the new tree"
    end
  end

  # A REFUSED CI READ (401/403) IS THE TOKEN, NOT A VERDICT — and what the deferred
  # refusal owes the reader about it SPLITS ON THE ROLE, because what is standing beside
  # it splits on the role. Both halves are pinned below, against the same fixture.
  #
  # THE CI TOKEN CARRIES A REAL 401 BODY, and that is load-bearing rather than realism.
  # unreadable_remedy branches on the CAUSE: a bare "unreadable" classifies to nothing
  # and takes the generic "forbidden response" text, which names NO command — so the
  # review half's `refute_includes "gh-auth-refresh"` would be asserted against a string
  # that could not have contained it whatever the code did. This file's whole subject is
  # a control that cannot fail, so it does not get to ship another one.
  UNREADABLE_401 = "unreadable:HTTP 401: Bad credentials"

  def credential_remedy?(text) = text.to_s.include?("This is a CREDENTIAL fault")

  # REVIEW ROLE — POINT AT THE ERROR BESIDE IT. Review's allow-list refuses on this same
  # state (a deferral can never clear an unread CI: that needs a FULL cert, which a
  # deferral is by definition not), so the CI gate's error IS raised alongside carrying
  # the ~500-character remedy in full. Printing the paragraph twice in one verdict is how
  # a reader learns to skim the thing we most need them to read.
  def test_an_unreadable_ci_points_at_the_credential_error_in_the_REVIEW_role
    with_desk do |projects, desk|
      verdict, code = dor_check(task_json([receipt_for(desk)]), desk, projects,
                                ci: UNREADABLE_401, role: "review")

      refute verdict["ready"], "a CI nobody could read is not a green one"
      assert_equal 1, code
      assert review_role_marker?(verdict), "this half only holds in the review role — it must BE one"
      refusal = defer_refusal(verdict)
      refute_nil refusal, "expected a deferral refusal: #{verdict['errors']}"
      assert_includes refusal, "carries the credential remedy", "it must POINT at the remedy beside it"
      assert_includes refusal, "NO local run underneath it",
                      "and still say the part that is specific to a deferral"
      refute credential_remedy?(refusal), "the remedy itself belongs to the CI error, printed once"
      refute_includes refusal, "gh-auth-refresh"

      # THE POINTER'S REFERENT, ASSERTED. "the error beside this one" is a claim about
      # the OTHER errors in this verdict, and a test that reads only the refusal cannot
      # tell a correct pointer from one aimed at nothing. That is exactly how the
      # role-blind version of this branch shipped.
      assert (Array(verdict["errors"]) - [refusal]).any? { |e| credential_remedy?(e) },
             "the error it points at must actually be there: #{verdict['errors']}"
    end
  end

  # BUILDER ROLE — PRINT THE REMEDY INLINE, because here there is nothing beside it to
  # point at. CiGate.verdict only reaches unread_ci_refusal when review_role, so
  # submit-side the CI gate raises no error for :unreadable at all and the remedy travels
  # as a suggestion. This is the role bin/ship runs, so it is the role a blocked builder
  # is actually reading — and it read a pointer to an error that was not on their screen.
  def test_an_unreadable_ci_prints_the_credential_remedy_inline_in_the_BUILDER_role
    with_desk do |projects, desk|
      verdict, code = dor_check(task_json([receipt_for(desk)]), desk, projects,
                                ci: UNREADABLE_401, role: "builder")

      refute verdict["ready"], "a CI nobody could read is not a green one"
      assert_equal 1, code
      refute review_role_marker?(verdict), "and this half only holds submit-side"
      refusal = defer_refusal(verdict)
      refute_nil refusal, "expected a deferral refusal: #{verdict['errors']}"
      assert credential_remedy?(refusal),
             "submit-side the refusal must CARRY the remedy, not point at one: #{refusal}"
      assert_includes refusal, "gh-auth-refresh", "and carry the command that actually clears it"
      assert_includes refusal, "NO local run underneath it",
                      "without losing the part that is specific to a deferral"
      refute_includes refusal, "carries the credential remedy",
                      "pointing at a neighbour that does not exist in this role is the defect"

      # THE PREMISE, ASSERTED RATHER THAN ASSUMED — inline is only right BECAUSE nothing
      # beside it carries the remedy. If CiGate ever starts refusing submit-side, this
      # fires and says so, instead of leaving a now-duplicated paragraph to be noticed by
      # a reader who has already learned to skim it.
      refute (Array(verdict["errors"]) - [refusal]).any? { |e| credential_remedy?(e) },
             "nothing else in this role's errors carries it — that is why it is inline: #{verdict['errors']}"
    end
  end

  # --- [unit] role independence ----------------------------------------------------

  # THE REVIEW GATE-ZERO GRADES IT THE SAME WAY, which is what keeps a deferred task
  # from dead-ending one rung later: review enforces the settled green, and a settled
  # green is precisely what this route already requires. The cert verdict is driven
  # through the injected seam so the ROLE is the only variable — and the role is now
  # actually a variable: it rides `role:` to --gate-role on the command line, and each
  # run is checked for the review-role marker before its verdict is believed.
  #
  # It did not used to be. This test shipped passing the role through `extra:`, which
  # is the child ENVIRONMENT, against a --gate-role that has no env seam — so it ran
  # the DEFAULT builder role twice and asserted role-independence by comparing a role
  # to itself. See the dor_check helper's header. Everything it claimed was true; it
  # simply could not see it, which is why the role-blind refusal in the same commit
  # walked past it.
  def test_the_review_role_credits_a_deferred_receipt_on_green_and_refuses_without_it
    with_desk do |projects, desk|
      ready, = dor_check(task_json([]), desk, projects, ci: "green", role: "review",
                                                        extra: { "DOR_CHECK_SUITE_EVIDENCE" => "deferred_fresh",
                                                                 "DOR_CHECK_PR_HEAD" => nil })
      assert review_role_marker?(ready),
             "this run must BE a review run — without the marker it is the builder default again"
      assert_equal "deferred", ready.dig("full_suite", "route"),
                   "review-side, an injected fresh deferral routes deferred: #{ready['errors']}"

      blocked, = dor_check(task_json([]), desk, projects, ci: "red", role: "review",
                                                          extra: { "DOR_CHECK_SUITE_EVIDENCE" => "deferred_fresh" })
      assert review_role_marker?(blocked), "and so must this one"
      refute blocked["ready"], "and a red CI refuses it in the same lane"
      assert_nil blocked.dig("full_suite", "route")
    end
  end

  # THE CONTROL FOR THE TEST ABOVE, and what makes its `role:` mean anything. A marker
  # asserted in the review role proves the role landed only if the BUILDER role does
  # NOT carry it; the failure being fenced is a flag that never arrives, and a fixture
  # reading identically in both roles cannot tell that from one that reads correctly.
  # So drive the SAME fixture through both roles and pin the two places they diverge:
  #
  #   ci_gate_result — CiGate.gate_row grades a PENDING CI "pending" submit-side and
  #                    "fail" for review. Structural: a field, not a sentence.
  #   the zap suggestion — review-only, the marker the test above leans on.
  #
  # A pending CI is the state to ask it in: a deferral has no provisional twin, so the
  # VERDICT is role-independent here (both refuse) and the discriminators are the only
  # thing separating the two runs. If this test ever fails by finding the two roles
  # identical, --gate-role stopped reaching the CLI and every "review" run in this file
  # is a builder run wearing the name.
  def test_the_gate_role_flag_actually_reaches_the_cli
    with_desk do |projects, desk|
      evidence = { "DOR_CHECK_SUITE_EVIDENCE" => "deferred_fresh" }
      builder, = dor_check(task_json([]), desk, projects, ci: "pending", role: "builder", extra: evidence)
      review, = dor_check(task_json([]), desk, projects, ci: "pending", role: "review", extra: evidence)

      assert_equal "pending", builder["ci_gate_result"], "submit-side a running CI is PENDING, not a failure"
      assert_equal "fail", review["ci_gate_result"],
                   "the review gate-zero fails a CI that has not settled — reading 'pending' here means the " \
                   "--gate-role flag never reached the CLI"

      refute review_role_marker?(builder), "the builder role must not carry the review-only marker"
      assert review_role_marker?(review), "and the review role must"

      refute builder["ready"], "a deferral has no provisional twin in EITHER role"
      refute review["ready"]
    end
  end

  # --- [unit] the injected tokens the seam above depends on ------------------------

  def test_the_injected_deferred_tokens_grade_only_the_defer_lane
    fresh = FullSuiteGate.injected_verdict("deferred_fresh")
    stale = FullSuiteGate.injected_verdict("deferred_stale")

    refute fresh[:ok], "a deferral is never a FULL cert — ok must stay false"
    assert_equal :fresh, fresh.dig(:lanes, FullSuiteGate::DEFER_LANE)
    assert_equal :missing, fresh.dig(:lanes, FullSuiteGate::FAST_LANE),
                 "the deferral must not masquerade as a fast cert"
    assert_equal :stale, stale.dig(:lanes, FullSuiteGate::DEFER_LANE)
  end

  # --- [integration] ONE remedy per verdict (/tasks/builder-reads-remedy-twice) ----
  #
  # HALF 1. The two role tests above proved the refusal CARRIES the remedy submit-side
  # and POINTS at it under review — and both of them looked only at `errors`. The
  # submit-side NOTE (bin/dor-check's `when :unreadable` suggestion) carries the same
  # ~500-character paragraph, and it is suppressed on `ci_review_refused` ONLY: a
  # role-shaped proxy for "an error already said this", true under review and FALSE for
  # the builder. So the role that reads it — bin/ship runs the builder role — read it
  # TWICE, in a verdict they are already blocked by.
  #
  # ACROSS BOTH LISTS, deliberately. Counting carriers within `errors` alone is exactly
  # the blindness that let this ship beside a test whose subject was this same string.
  def test_the_builder_role_prints_the_credential_remedy_exactly_once
    with_desk do |projects, desk|
      verdict, code = dor_check(task_json([receipt_for(desk)]), desk, projects,
                                ci: UNREADABLE_401, role: "builder")

      refute verdict["ready"], "a CI nobody could read is not a green one"
      assert_equal 1, code
      refute review_role_marker?(verdict), "this half only holds submit-side"

      printed = Array(verdict["errors"]) + Array(verdict["suggestions"])
      carriers = printed.select { |text| credential_remedy?(text) }

      assert_equal 1, carriers.size,
                   "the ONE REMEDY STRING must appear ONCE in a verdict, counting errors AND " \
                   "suggestions — a remedy printed twice trains the reader to skim the thing they " \
                   "most need to read:\n#{carriers.join("\n---\n")}"
      assert credential_remedy?(defer_refusal(verdict)),
             "and the surviving copy must be the REFUSAL — that is the list a blocked builder reads"
    end
  end

  # THE FENCE, and it is the half that makes the dedupe honest rather than a silencing.
  # With a FULL cert standing, the suite gate does not refuse, so NO error carries the
  # remedy — and the submit-side note is then the only thing between a builder and a
  # token they have to refresh. It must still print, in full. Printing it once is the
  # goal; printing it zero times is the worse defect wearing the fix's clothes.
  def test_a_builder_whose_cert_stands_still_receives_the_remedy
    with_desk do |projects, desk|
      verdict, = dor_check(task_json([]), desk, projects, ci: UNREADABLE_401, role: "builder",
                                                          extra: { "DOR_CHECK_SUITE_EVIDENCE" => "ok" })

      errors = Array(verdict["errors"])
      refute errors.any? { |text| credential_remedy?(text) },
             "the premise: with the cert standing, no ERROR carries the remedy here — if one does, " \
             "this fixture stopped testing what it says:\n#{errors.join("\n---\n")}"
      assert Array(verdict["suggestions"]).any? { |text| credential_remedy?(text) },
             "so the submit-side note MUST carry it — suppressing it here would trade a noisy " \
             "correct message for a missing one:\n#{Array(verdict['suggestions']).join("\n---\n")}"
    end
  end

  # HALF 2. The gated route ends by naming the full cert, and it named it with the
  # LITERAL `<task>` — a token the reader cannot type, printed to a builder whose task
  # slug is the one thing this run definitely knows. Same defect class as
  # /tasks/release-offers-retired-cert, which removed an unfillable placeholder at G3
  # rather than leaving it to be ignored; here a slug EXISTS, so the honest fix is to
  # name it. Asserted on the RENDERED verdict, in both roles, because the defect is the
  # output and a unit test on the formatter cannot see whether the wiring hands it one.
  def test_no_printed_remedy_carries_an_unfillable_placeholder
    with_desk do |projects, desk|
      %w[builder review].each do |role|
        verdict, = dor_check(task_json([receipt_for(desk)]), desk, projects,
                             ci: UNREADABLE_401, role: role)
        printed = (Array(verdict["errors"]) + Array(verdict["suggestions"])).join("\n")

        refute_includes printed, "bin/full-suite-check <task>",
                        "#{role}: the cert offer must name a command the reader can TYPE — this run " \
                        "knows the slug:\n#{printed}"
        # SCOPED TO THE REMEDY'S OWN CLAUSE, not to the slug appearing anywhere. The
        # dor-check sentence WRAPPING the remedy independently ends "or certify locally
        # in full: bin/full-suite-check <slug>" — so a bare `bin/full-suite-check #{SLUG}`
        # assertion is satisfied by the neighbour and says nothing about the remedy.
        # Measured: deleting the offer from ci_status.rb left that looser form GREEN.
        # STILL SCOPED TO THE REMEDY'S OWN CLAUSE (see above), but no longer keyed on the
        # BARE spelling: remedy-hints-second-wave routed this offer through
        # FastLane.remedy_command, so the clause now carries an ABSOLUTE
        # bin/full-suite-check a satellite or gem desk can actually run. Keyed on the
        # FILESYSTEM rather than on the text, for the reason
        # test/lib/remedy_hint_guard_test.rb spells out: an absolute path CONTAINS the
        # bare form, so a substring assertion is blind in BOTH directions.
        offer = printed[/certify in full instead: (\S+) #{Regexp.escape(SLUG)}\./, 1]
        refute_nil offer,
                   "#{role}: the offer must survive AND name THIS task — deleting it would satisfy " \
                   "the placeholder half while losing the route the gate honours:\n#{printed}"
        assert_equal File.expand_path(offer), offer,
                     "#{role}: the cert offer must be an ABSOLUTE command — a builder on a satellite " \
                     "or gem desk cannot run the bare form:\n#{printed}"
        assert File.executable?(offer),
               "#{role}: the cert offer names #{offer.inspect}, which is not an executable on this disk:\n#{printed}"
        assert_equal "full-suite-check", File.basename(offer),
                     "#{role}: the offer must name the FULL cert, not #{File.basename(offer)}:\n#{printed}"
      end
    end
  end

  # The lane has to be MACHINE-OWNED or an author `--checks` update wipes the receipt
  # and strands the build. Asserted against the shipped list, not assumed.
  def test_the_defer_lane_is_part_of_the_machine_owned_evidence_namespace
    assert_includes FullSuiteGate::EVIDENCE_LANES, FullSuiteGate::DEFER_LANE
    refute_includes FullSuiteGate::LANES, FullSuiteGate::DEFER_LANE,
                    "it must NOT be a lane the FULL cert waits on — that would demand it of every shape"
  end
end
