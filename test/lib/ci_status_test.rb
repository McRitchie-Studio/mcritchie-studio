# frozen_string_literal: true

# Unit test for bin/lib/ci_status.rb — the GitHub-CI verdict the dor-check merge gate
# reads. Pure mapping (gh `bucket` → state); no network. Run directly:
#   ruby -Itest test/lib/ci_status_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "tmpdir"
require_relative "../../bin/lib/ci_status"

class CiStatusTest < Minitest::Test
  def test_red_when_a_check_fails
    v = CiStatus.parse('[{"name":"test","bucket":"fail"},{"name":"lint","bucket":"pass"}]')
    assert_equal :red, v[:state]
    assert_equal ["test"], v[:failing]
  end

  def test_red_on_a_cancelled_check
    assert_equal :red, CiStatus.parse('[{"name":"e2e","bucket":"cancel"}]')[:state]
  end

  def test_pending_when_running_and_nothing_failed
    v = CiStatus.parse('[{"name":"e2e","bucket":"pending"},{"name":"lint","bucket":"pass"}]')
    assert_equal :pending, v[:state]
    assert_equal ["e2e"], v[:pending]
  end

  def test_a_failure_outranks_a_still_running_check
    # fail + pending together is RED, not pending — a known-bad PR is never "not yet".
    assert_equal :red, CiStatus.parse('[{"name":"test","bucket":"fail"},{"name":"e2e","bucket":"pending"}]')[:state]
  end

  def test_green_when_every_check_passed_or_skipped
    v = CiStatus.parse('[{"name":"lint","bucket":"pass"},{"name":"scan","bucket":"skipping"}]')
    assert_equal :green, v[:state]
    assert_equal 2, v[:count]
  end

  def test_none_when_empty_or_no_checks_reported
    assert_equal :none, CiStatus.parse("[]")[:state]
    assert_equal :none, CiStatus.parse("no checks reported on the 'feat/x' branch")[:state]
  end

  def test_unverified_on_a_gh_or_network_error
    v = CiStatus.parse("gh: command not found")
    assert_equal :unverified, v[:state]
    assert_includes v[:reason], "command not found"
  end

  def test_a_bare_token_short_circuits_the_gh_call
    # the DOR_CHECK_CI_STATUS injection seam — used by the dor-check CLI tests. Includes
    # closed/merged: a non-open PR is its own verdict, never green (carl's review catch).
    # Includes conflicted: a merge-conflicted PR (mergeStateStatus DIRTY) gets NO CI at
    # all, and must be its own verdict — never folded into :none (the PR-#509 stall).
    %i[green red pending none unverified no_pr closed merged conflicted].each do |state|
      assert_equal state, CiStatus.evaluate("https://github.com/x/pull/1", state.to_s)[:state]
    end
  end

  # --- the `gh pr view` payload → early verdict (view_verdict) -----------------
  # A PR with merge conflicts against its base reports mergeStateStatus DIRTY, and
  # GitHub CANNOT compute the merge commit — so the pull_request workflow never
  # fires. That PR has NO CI, not a pending one: reading only the checks folds it
  # into :none ("defer until CI reports") and the PR stalls in submitted forever
  # (PR #509, 2026-07-12). view_verdict reads state + mergeStateStatus in one gh
  # call and surfaces :conflicted as its own state.

  def view(state, merge_state, mergeable: nil, base: nil)
    payload = { "state" => state, "mergeStateStatus" => merge_state }
    payload["mergeable"] = mergeable if mergeable
    payload["baseRefName"] = base if base
    JSON.generate(payload)
  end

  def test_view_verdict_conflicted_when_the_open_pr_is_dirty
    v = CiStatus.view_verdict(view("OPEN", "DIRTY"))
    assert_equal :conflicted, v[:state]
    assert_equal "DIRTY", v[:merge_state]
  end

  def test_view_verdict_proceeds_to_the_checks_read_when_mergeable
    # nil = "no early verdict — go read the checks". BEHIND/UNSTABLE/BLOCKED are
    # CI/branch-protection colour, not conflicts; UNKNOWN is GitHub still
    # computing mergeability — never invented as a conflict.
    %w[CLEAN BEHIND UNSTABLE BLOCKED HAS_HOOKS UNKNOWN DRAFT].each do |merge_state|
      assert_nil CiStatus.view_verdict(view("OPEN", merge_state)),
                 "OPEN + #{merge_state} must fall through to `gh pr checks`"
    end
  end

  def test_view_verdict_closed_and_merged_outrank_dirty
    # A closed/merged PR is its own verdict even when it also reads DIRTY —
    # "rebase and resubmit" is the wrong instruction for a dead review target.
    assert_equal :closed, CiStatus.view_verdict(view("CLOSED", "DIRTY"))[:state]
    assert_equal :merged, CiStatus.view_verdict(view("MERGED", "UNKNOWN"))[:state]
  end

  def test_view_verdict_unverified_on_a_gh_error_body
    v = CiStatus.view_verdict("gh: Not Found (HTTP 404)")
    assert_equal :unverified, v[:state]
    assert_includes v[:reason], "Not Found"
  end

  # --- the CI-LESS third state (task detect-ci-less-stale-prs, 2026-07-20) -----
  #
  # REGRESSION. When a PR's base drifts far enough that GitHub cannot compute a
  # merge commit, GitHub runs NO CI AT ALL: the head SHA has zero check-runs and
  # mergeStateStatus reads UNKNOWN/DIRTY. Reading only the checks folds that into
  # :none, which every watcher in the fleet treats as "CI is still coming" — so it
  # waits forever on checks that will NEVER exist. That burned a full rework cycle
  # (a watcher armed at 05:47Z on a commit that never got checks; the cure was a
  # rebase, which triggered CI green 8/8 immediately).
  #
  # "No CI will run" is a THIRD state, not a slow :pending: its remedy is a rebase,
  # and no amount of waiting substitutes. These vectors pin the CLASSIFICATION
  # property — four inputs, four DISTINCT verdicts — not any message spelling.

  # The four vectors, as `combine` sees them: [gh pr view payload, gh pr checks payload].
  def ci_vectors
    {
      # checks EXIST and have not concluded — CI is genuinely coming. Wait.
      pending: [view("OPEN", "BLOCKED", mergeable: "MERGEABLE", base: "accepted"),
                '[{"name":"test","bucket":"pending"}]'],
      # ZERO checks AND GitHub will not confirm the merge — CI is NEVER coming. Rebase.
      ci_less: [view("OPEN", "UNKNOWN", mergeable: "CONFLICTING", base: "accepted"),
                "[]"],
      green: [view("OPEN", "CLEAN", mergeable: "MERGEABLE", base: "accepted"),
              '[{"name":"test","bucket":"pass"}]'],
      red: [view("OPEN", "UNSTABLE", mergeable: "MERGEABLE", base: "accepted"),
            '[{"name":"test","bucket":"fail"}]']
    }
  end

  def test_combine_classifies_each_ci_vector_as_its_own_state
    ci_vectors.each do |expected, (view_raw, checks_raw)|
      assert_equal expected, CiStatus.combine(view_raw, checks_raw)[:state],
                   "#{expected} vector must classify as :#{expected}"
    end
  end

  def test_the_four_ci_vectors_never_collapse_into_each_other
    # The POSITIVE invariant: four distinct inputs → four distinct verdicts. A fix
    # that folded ci-less back into pending (or into green, or red) fails here even
    # if every message string still reads well.
    states = ci_vectors.values.map { |view_raw, checks_raw| CiStatus.combine(view_raw, checks_raw)[:state] }
    assert_equal states.uniq.size, states.size, "each CI vector must be distinguishable: #{states.inspect}"
  end

  def test_ci_less_is_not_pending_not_green_not_red_and_not_none
    # The bug verbatim: the ci-less PR read as one of these and the watcher waited
    # forever. It must be none of them — waiting is the wrong instruction.
    view_raw, checks_raw = ci_vectors[:ci_less]
    state = CiStatus.combine(view_raw, checks_raw)[:state]
    refute_includes %i[pending green red none], state,
                    "a PR that will never get CI must not report a state that means 'wait'"
  end

  def test_ci_less_carries_an_actionable_remedy_naming_its_base
    # ACTIONABLE, not merely distinct: the reader must learn the cure without
    # re-deriving it. Asserts the base branch is CARRIED and reaches a runnable
    # command — deliberately not the verb, which round 3 changed from `rebase` to
    # `merge` for recoverability. Pinning the spelling is how a test starts arguing
    # for the wrong fix.
    view_raw, checks_raw = ci_vectors[:ci_less]
    v = CiStatus.combine(view_raw, checks_raw)
    assert_equal "accepted", v[:base]
    remedy = CiStatus.ci_less_remedy(v)
    assert_match(%r{git \w+ origin/accepted\b}, remedy, "the remedy runs against the PR's actual base")
  end

  def test_zero_checks_on_a_confirmed_mergeable_pr_stays_none
    # The GUARD against over-reach. Zero checks alone is NOT ci-less: a PR GitHub
    # affirms is mergeable simply has not started its run yet, and that IS a wait.
    # Only the conjunction (no checks AND no confirmed merge) is the third state.
    v = CiStatus.combine(view("OPEN", "CLEAN", mergeable: "MERGEABLE", base: "accepted"), "[]")
    assert_equal :none, v[:state]
  end

  def test_ci_less_never_overrides_a_payload_that_reported_checks
    # A PR that HAS checks is never ci-less, however ugly its merge state — the
    # checks are the evidence that CI ran.
    v = CiStatus.combine(view("OPEN", "UNKNOWN", mergeable: "CONFLICTING", base: "accepted"),
                         '[{"name":"test","bucket":"pass"}]')
    assert_equal :green, v[:state]
  end

  def test_combine_keeps_the_early_view_verdicts
    # DIRTY is already :conflicted (PR #509) and outranks the ci-less read; a
    # closed/merged PR is still its own verdict. combine must not regress those.
    assert_equal :conflicted, CiStatus.combine(view("OPEN", "DIRTY", mergeable: "CONFLICTING"), "[]")[:state]
    assert_equal :closed, CiStatus.combine(view("CLOSED", "UNKNOWN", mergeable: "CONFLICTING"), "[]")[:state]
  end

  def test_a_view_payload_without_the_mergeable_field_never_invents_ci_less
    # BACKWARD COMPAT. A caller that did not ASK for `mergeable` must not have its
    # silence read as "not mergeable" — absence of evidence is not evidence.
    assert_equal :none, CiStatus.combine(view("OPEN", "UNKNOWN"), "[]")[:state]
  end

  # --- ROUND 2: UNKNOWN mergeability is NOT a negative verdict ------------------
  #
  # Review blocked round 1 (avi, siding with jasper's light lane; carl's primary
  # lane found the same defect and rated it non-blocking — the CONVERGENCE is why it
  # blocked). The round-1 predicate was SELF-INCONSISTENT: an ABSENT `mergeable`
  # counted as confirmed, while an explicit "UNKNOWN" did not — though both mean the
  # SAME thing, that GitHub has not told us it cannot merge.
  #
  # Why that was not cosmetic: GitHub computes mergeability ASYNCHRONOUSLY after
  # every push, answering UNKNOWN until it lands, and a brand-new head SHA has zero
  # check-runs in that SAME window. Both halves of the conjunction are therefore true
  # at once for a perfectly HEALTHY PR — and that window is exactly when builders run
  # these tools, because the operating model prescribes "push, open a PR, then run
  # bin/dor-check". A reviewer watched #588, #601 and #602 all flip to UNKNOWN within
  # seconds of an unrelated merge and settle back with NO push.
  #
  # The harm is not the stale verdict, it is the INSTRUCTION the verdict carries: a
  # hard block reading "waiting can never clear it… rebase and --force-with-lease".
  # A compliant agent force-pushes a healthy branch and cancels its in-flight CI.
  #
  # THE RULE, now three-valued: mergeability is AFFIRMED, REFUTED, or UNKNOWN, and
  # UNKNOWN is never converted into an actionable negative. Uncertainty about
  # GITHUB'S KNOWLEDGE falls toward wait; only an affirmative negative blocks. The
  # asymmetry justifies it — a wrong block force-pushes a healthy branch, a wrong
  # wait costs a bounded timeout.

  def test_undetermined_mergeability_is_a_wait_not_ci_less
    # The exact vector review prescribed. UNKNOWN + zero checks = the fresh-push
    # window, not a stale base.
    v = CiStatus.combine(view("OPEN", "UNKNOWN", mergeable: "UNKNOWN", base: "accepted"), "[]")
    assert_equal :none, v[:state]
  end

  def test_a_settled_merge_state_confirms_regardless_of_mergeable
    # Carl's sharper vector: CLEAN literally means GitHub DID compute the merge, so
    # {CLEAN, mergeable UNKNOWN, zero checks} was self-contradictory AND classified
    # ci-less. Any SETTLED mergeStateStatus is confirmation — it is the field that
    # actually reports settlement. Driven from the LITERAL list, not the constant, for
    # the same reason as blocker 1 below: iterating the constant would let a dropped
    # member escape the assertion.
    REQUIRED_SETTLED_STATES.each do |settled|
      v = CiStatus.combine(view("OPEN", settled, mergeable: "UNKNOWN", base: "accepted"), "[]")
      assert_equal :none, v[:state], "#{settled} means GitHub computed the merge — never ci-less"
    end
  end

  def test_absent_and_unknown_mergeable_are_treated_identically
    # THE self-inconsistency, asserted as an EQUIVALENCE rather than two spellings:
    # both inputs say "GitHub has not told us it cannot merge", so no reading of the
    # pair may ever diverge.
    %w[UNKNOWN CLEAN BEHIND].each do |merge_state|
      absent = CiStatus.combine(view("OPEN", merge_state), "[]")
      unknown = CiStatus.combine(view("OPEN", merge_state, mergeable: "UNKNOWN"), "[]")
      assert_equal absent[:state], unknown[:state],
                   "absent vs explicit-UNKNOWN mergeable must agree at #{merge_state}"
    end
  end

  def test_mergeability_is_three_valued
    # The POSITIVE invariant behind all of the above: three states, and only the
    # REFUTED one is actionable. Absence of signal is never negative signal.
    assert_equal :affirmed, CiStatus.mergeability(view("OPEN", "CLEAN", mergeable: "MERGEABLE"))
    assert_equal :affirmed, CiStatus.mergeability(view("OPEN", "UNSTABLE", mergeable: "UNKNOWN")),
                 "a settled merge state affirms even when `mergeable` lags"
    assert_equal :refuted, CiStatus.mergeability(view("OPEN", "DIRTY", mergeable: "CONFLICTING"))
    assert_equal :refuted, CiStatus.mergeability(view("OPEN", "UNKNOWN", mergeable: "CONFLICTING")),
                 "CONFLICTING is an affirmative negative"
    assert_equal :unknown, CiStatus.mergeability(view("OPEN", "UNKNOWN", mergeable: "UNKNOWN"))
    assert_equal :unknown, CiStatus.mergeability(view("OPEN", "UNKNOWN")),
                 "an absent mergeable is UNKNOWN, not affirmed and not refuted"
  end

  def test_an_undetermined_mergeability_names_its_uncertainty
    # UNKNOWN + zero checks is not a verdict, and it is not silence either: the
    # verdict REPORTS that GitHub has not decided, so a reader can tell "no data yet"
    # from "checks are running" without being handed an action nobody can justify.
    v = CiStatus.combine(view("OPEN", "UNKNOWN", mergeable: "UNKNOWN", base: "accepted"), "[]")
    assert_equal :none, v[:state]
    assert_equal :unknown, v[:mergeability], "the uncertainty must be named, not swallowed"
  end

  def test_a_refuted_merge_is_ci_less_on_the_FIRST_read
    # No backoff for an affirmative negative — CONFLICTING is GitHub telling us it
    # cannot merge, which is a fact, not a pending computation.
    v = CiStatus.combine(view("OPEN", "UNKNOWN", mergeable: "CONFLICTING", base: "accepted"), "[]")
    assert_equal :ci_less, v[:state]
  end

  # --- ROUND 3 -----------------------------------------------------------------
  #
  # BLOCKER 1 (both lanes): BOUND EXHAUSTION MUST NOT MANUFACTURE CONFIDENCE.
  # Round 2 let a second look convert an undetermined mergeability into a hard
  # :ci_less — so the SAME payload it correctly called :none became a confident block
  # five seconds later, emitting `--force-with-lease` advice at a healthy PR. That is
  # round 1's harm on a timer. It also contradicted this module's own stated fail
  # direction ("uncertainty falls toward wait") and gates/g2-review.md.
  #
  # The discriminator was never sound: ONE 5s retry against an asynchronous GitHub
  # computation that publishes no SLA. Running out of patience is not evidence. A
  # stable-unknown block would need a live PR observed staying UNKNOWN indefinitely, a
  # bound sized to GitHub's real settling time, and a test of the re-read loop — none
  # of which existed, and the loop itself was untested.
  #
  # So the bound is GONE, and with it the sleep on a hot path both dor-check and
  # pr-review call. :ci_less now has EXACTLY ONE producer: an affirmative negative.

  def test_ci_less_has_exactly_one_producer_an_affirmative_negative
    # THE invariant, asserted over the whole input space rather than by spot-checking
    # spellings: across every merge-state x mergeable pairing, :ci_less appears if and
    # only if mergeability is :refuted. No amount of uncertainty can produce it.
    merge_states = %w[CLEAN BLOCKED BEHIND UNSTABLE HAS_HOOKS DRAFT UNKNOWN] + [nil]
    mergeables = %w[MERGEABLE CONFLICTING UNKNOWN] + [nil]
    merge_states.each do |ms|
      mergeables.each do |m|
        raw = view("OPEN", ms || "", mergeable: m, base: "accepted")
        state = CiStatus.combine(raw, "[]")[:state]
        refuted = CiStatus.mergeability(raw) == :refuted
        assert_equal refuted, state == :ci_less,
                     "ci_less iff refuted — #{ms.inspect}/#{m.inspect} gave :#{state}"
      end
    end
  end

  def test_no_bound_exhaustion_path_remains
    # The removal, pinned: `combine` takes exactly two arguments. A future
    # reintroduction of a "we waited long enough" flag fails here and has to argue
    # for itself on the evidence this round said it would need.
    assert_equal 2, CiStatus.method(:combine).arity,
                  "combine must not regain a stability/exhaustion parameter"
    refute CiStatus.respond_to?(:recheck_seconds),
           "the timing heuristic is gone — no retry bound to exhaust"
  end

  # BLOCKER 2: PRECEDENCE — round 1's defect in mirror image. `:refuted` was tested
  # BEFORE settlement, so a settled merge state lost to a stale async `mergeable`:
  # {CLEAN + CONFLICTING} classified :refuted => :ci_less, contradicting this module's
  # own docstring ("their presence is settlement, whatever mergeable says") and firing
  # an IMMEDIATE force-push instruction at a healthy PR — the precise harm this work
  # exists to prevent. Round 2 fixed {CLEAN + mergeable UNKNOWN}; this is that shape.

  # The settled merge states, enumerated INDEPENDENTLY of the constant under test —
  # round 4, blocker 1. A loop over `CiStatus::SETTLED_MERGE_STATES` cannot catch a
  # member being DROPPED from that constant, because the constant is also the loop's
  # source: remove CLEAN and CLEAN simply leaves the iteration, no assertion fires,
  # and {CLEAN + CONFLICTING} silently returns to :ci_less — round-3 blocker 2's exact
  # harm. So the expectation is a literal list here; a divergence between it and the
  # constant is the bug.
  REQUIRED_SETTLED_STATES = %w[CLEAN BLOCKED BEHIND UNSTABLE HAS_HOOKS DRAFT].freeze

  def test_the_settled_states_constant_contains_every_required_member
    # MEMBERSHIP, asserted against the independent list. Dropping CLEAN (or DRAFT —
    # mutation M15) from the constant fails HERE, whatever the rung order does.
    REQUIRED_SETTLED_STATES.each do |state|
      assert_includes CiStatus::SETTLED_MERGE_STATES, state,
                      "#{state} must be treated as a settled merge state"
    end
  end

  def test_every_required_settled_state_outranks_a_stale_conflicting_mergeable
    # THE POSITIVE PROPERTY, driven from the literal list, not the constant. For each
    # state GitHub uses to say "I computed the merge", a lagging CONFLICTING must not
    # win — the PR is affirmed and a healthy PR with zero checks is a wait, never
    # ci-less.
    REQUIRED_SETTLED_STATES.each do |settled|
      raw = view("OPEN", settled, mergeable: "CONFLICTING", base: "accepted")
      assert_equal :affirmed, CiStatus.mergeability(raw),
                   "#{settled} is settlement — it must outrank a lagging CONFLICTING"
      assert_equal :none, CiStatus.combine(raw, "[]")[:state],
                   "#{settled} + CONFLICTING must not block a healthy PR"
    end
  end

  def test_dirty_still_refutes_even_though_it_is_settled
    # DIRTY is the settled NEGATIVE, so it must not be swept up by "settlement
    # affirms" — it is the one merge state that both settles AND refutes.
    assert_equal :refuted, CiStatus.mergeability(view("OPEN", "DIRTY", mergeable: "MERGEABLE"))
  end

  # BLOCKER 3: PRINTED ADVICE MUST FAIL SAFELY, NOT JUST SUCCEED.
  #
  # The round-2 remedy was `git fetch origin && git rebase origin/<base> && git push
  # --force-with-lease`. But :refuted fires on `mergeable CONFLICTING` — GitHub
  # affirming REAL conflicts — so the rebase HALTS, the `&&` chain stops silently, the
  # push never runs, and the operator is left mid-rebase with no next instruction. The
  # remedy never said "resolve the conflicts". The same defect appeared independently
  # in a sibling PR the same day, which is why it is a standing lesson: we test that
  # printed advice SUCCEEDS and never that it FAILS SAFELY.
  #
  # These assert the property (recoverable + clearly labeled), not the prose.

  def refuted_remedy
    CiStatus.ci_less_remedy(CiStatus.ci_less_verdict(view("OPEN", "UNKNOWN", mergeable: "CONFLICTING", base: "accepted")))
  end

  def test_the_remedy_never_chains_past_a_step_that_can_halt
    # An && chain is the defect itself: it hides the stop. Steps that can pause must
    # be given one at a time.
    refute_includes refuted_remedy, "&&", "the remedy must not chain commands that can halt mid-way"
  end

  def test_the_remedy_names_the_conflict_work_and_a_way_back
    # The two things the stranded operator needed and did not get: what to DO when it
    # stops, and how to get back to a known-good state.
    remedy = refuted_remedy
    assert_match(/resolve/i, remedy, "the remedy must tell the operator to resolve conflicts")
    assert_match(/--abort/, remedy, "the remedy must name a way back to a known-good state")
  end

  def test_the_remedy_leaves_a_conflicted_repo_recoverable_and_labeled
    # EXECUTED, not asserted about. Builds a real conflict, runs the remedy's merge
    # step, and proves the operator ends somewhere recoverable and clearly labeled —
    # then that the named recovery actually restores the original commit.
    Dir.mktmpdir do |dir|
      git = ->(*args) { system("git", "-C", dir, *args, out: File::NULL, err: File::NULL) }
      git.call("init", "-q", "-b", "accepted")
      git.call("config", "user.email", "t@t.test")
      git.call("config", "user.name", "T")
      File.write(File.join(dir, "f.txt"), "base\n")
      git.call("add", "-A")
      git.call("commit", "-qm", "base")

      # A feature branch and the base BOTH edit the same line — a real conflict.
      git.call("checkout", "-qb", "feat")
      File.write(File.join(dir, "f.txt"), "feature\n")
      git.call("add", "-A")
      git.call("commit", "-qm", "feature")
      feature_head = `git -C #{dir} rev-parse HEAD`.strip

      git.call("checkout", "-q", "accepted")
      File.write(File.join(dir, "f.txt"), "moved\n")
      git.call("add", "-A")
      git.call("commit", "-qm", "moved")
      git.call("checkout", "-q", "feat")

      # The remedy's merge step, run exactly as printed. It MUST fail — that is the
      # conflicting condition — and it must stop somewhere the operator can leave.
      merged = git.call("merge", "accepted")
      refute merged, "the merge must halt on a real conflict (that is the condition under test)"

      status = `git -C #{dir} status --porcelain`
      assert_match(/^(UU|AA)/, status, "the conflict is LABELED in the worktree, not silent")
      assert_path_exists File.join(dir, ".git", "MERGE_HEAD"), "the operator is in a named, inspectable state"

      # And the way back the remedy names actually works.
      assert git.call("merge", "--abort"), "the remedy's named recovery must succeed"
      assert_equal feature_head, `git -C #{dir} rev-parse HEAD`.strip,
                   "aborting returns the branch to exactly where it started"
      assert_empty `git -C #{dir} status --porcelain`.strip, "recovery leaves a clean tree"
    end
  end

  # BLOCKER 4: a placeholder must never reach a RUNNABLE command. `base = "the base
  # branch" if base.empty?` was interpolated straight into `git rebase origin/<base>`,
  # printing `git rebase origin/the base branch` — and pr-review writes this string
  # into REAL task block feedback.

  def test_an_unknown_base_never_produces_a_runnable_command
    remedy = CiStatus.ci_less_remedy(CiStatus.ci_less_verdict(view("OPEN", "UNKNOWN", mergeable: "CONFLICTING")))
    refute_match(%r{origin/\S*\s}, remedy, "no half-built origin/<placeholder> ref may be printed")
    refute_match(/git (merge|rebase|fetch)/, remedy,
                 "with no base resolved the remedy must omit the commands, not guess them")
    assert_match(/base/i, remedy, "it still has to say what is missing")
  end

  def test_a_known_base_produces_a_command_naming_that_base
    remedy = refuted_remedy
    assert_match(%r{git merge origin/accepted\b}, remedy)
  end

  # --- conflict-remedy-names-wrong-branch -------------------------------------
  # The :conflicted (mergeStateStatus DIRTY) remedy must read the PR's ACTUAL base,
  # not a hardcoded `release`. Feature PRs target `accepted`, so "git merge
  # origin/release" names the WRONG branch and would pull unreviewed release-only
  # content into the PR. This mirrors the :ci_less remedy, which already got it
  # right — same properties, asserted for :conflicted.

  def test_view_verdict_conflicted_carries_the_pr_base
    v = CiStatus.view_verdict(view("OPEN", "DIRTY", base: "accepted"))
    assert_equal :conflicted, v[:state]
    assert_equal "accepted", v[:base], "the conflicted verdict must surface the PR's base so the remedy can name it"
  end

  def conflicted_remedy_for(base)
    CiStatus.conflicted_remedy(CiStatus.view_verdict(view("OPEN", "DIRTY", base: base)))
  end

  def test_conflicted_remedy_names_the_pr_base_not_a_hardcoded_release
    remedy = conflicted_remedy_for("accepted")
    assert_match(%r{git merge origin/accepted\b}, remedy, "the remedy must merge the PR's ACTUAL base")
    refute_match(%r{origin/release\b}, remedy, "it must NOT hardcode release — feature PRs target accepted")
  end

  def test_conflicted_remedy_is_failure_safe_merge_not_rebase_with_a_way_back
    remedy = conflicted_remedy_for("accepted")
    refute_includes remedy, "&&", "no && chain past a step that can halt (the advice-failure-path lesson)"
    assert_match(%r{git merge origin/accepted}, remedy, "prefer merge — a halted merge leaves the branch untouched")
    refute_match(/git rebase/, remedy, "a rebase halt rewrites history; the conflict remedy must merge")
    assert_match(/--abort/, remedy, "the remedy must name a way back to a known-good state")
    assert_match(/resolve/i, remedy, "and tell the operator to resolve the conflicts")
  end

  def test_conflicted_remedy_omits_commands_when_the_base_is_unknown
    remedy = CiStatus.conflicted_remedy(CiStatus.view_verdict(view("OPEN", "DIRTY")))
    refute_match(%r{origin/\S*\s}, remedy, "no half-built origin/<placeholder> ref may be printed")
    refute_match(/git (merge|rebase|fetch)/, remedy, "with no base resolved, omit the commands — never guess them")
    assert_match(/base/i, remedy, "it still has to say what is missing")
  end

  # [integration] The SAME fix must land in BOTH callers — neither bin/pr-review nor
  # bin/dor-check may hardcode the conflict cure's branch; both route through
  # CiStatus.conflicted_remedy so one PR cannot collect three cures (the ci_less lesson).
  def test_pr_review_and_dor_check_do_not_hardcode_the_conflict_branch
    %w[pr-review dor-check].each do |bin|
      src = File.read(File.expand_path("../../bin/#{bin}", __dir__))
      refute_match(%r{git merge origin/release},  src,
                   "bin/#{bin} must not hardcode `git merge origin/release` in the conflict remedy")
      assert_includes src, "conflicted_remedy",
                       "bin/#{bin} must route the :conflicted cure through CiStatus.conflicted_remedy"
    end
  end

  def test_ci_less_is_an_injectable_token
    # The DOR_CHECK_CI_STATUS / PR_REVIEW_CI_STATUS seam, so the CLI tests can drive
    # the state without a network.
    assert_equal :ci_less, CiStatus.evaluate("https://github.com/x/pull/1", "ci_less")[:state]
  end

  def test_no_pr_when_url_blank_and_nothing_injected
    assert_equal :no_pr, CiStatus.evaluate("", nil)[:state]
    assert_equal :no_pr, CiStatus.evaluate(nil, "")[:state]
  end

  def test_names_a_check_by_its_state_when_the_name_is_missing
    v = CiStatus.parse('[{"state":"FAILURE","bucket":"fail"}]')
    assert_equal :red, v[:state]
    assert_equal ["FAILURE"], v[:failing]
  end

  # --- SHA-addressed CI (G3's auditor): the check-runs payload ----------------
  #
  # `gh api repos/{owner}/{repo}/commits/{sha}/check-runs` returns the RAW GitHub
  # pair status+conclusion, not gh's `bucket`. These pin the mapping shim — the
  # only new logic between the release gate and a verdict it already understands.

  # The API envelope a real gh api call returns.
  def check_runs(*runs)
    JSON.generate("total_count" => runs.size, "check_runs" => runs)
  end

  def test_check_runs_red_when_a_completed_run_failed
    v = CiStatus.parse_check_runs(check_runs(
                                    { "name" => "test", "status" => "completed", "conclusion" => "failure" },
                                    { "name" => "lint", "status" => "completed", "conclusion" => "success" }
                                  ))
    assert_equal :red, v[:state]
    assert_equal ["test"], v[:failing]
  end

  def test_check_runs_red_on_cancelled_timed_out_and_action_required
    %w[cancelled timed_out action_required startup_failure stale].each do |conclusion|
      v = CiStatus.parse_check_runs(check_runs({ "name" => "e2e", "status" => "completed", "conclusion" => conclusion }))
      assert_equal :red, v[:state], "a #{conclusion} run is a FAILED run"
    end
  end

  def test_check_runs_pending_while_a_run_is_queued_or_in_progress
    %w[queued in_progress].each do |status|
      v = CiStatus.parse_check_runs(check_runs(
                                      { "name" => "test", "status" => status, "conclusion" => nil },
                                      { "name" => "lint", "status" => "completed", "conclusion" => "success" }
                                    ))
      assert_equal :pending, v[:state], "a #{status} run has not reported a verdict yet"
      assert_equal ["test"], v[:pending]
    end
  end

  def test_check_runs_a_failure_outranks_a_still_running_run
    v = CiStatus.parse_check_runs(check_runs(
                                    { "name" => "test", "status" => "completed", "conclusion" => "failure" },
                                    { "name" => "e2e", "status" => "in_progress", "conclusion" => nil }
                                  ))
    assert_equal :red, v[:state]
  end

  def test_check_runs_green_when_every_run_passed_neutral_or_skipped
    v = CiStatus.parse_check_runs(check_runs(
                                    { "name" => "test", "status" => "completed", "conclusion" => "success" },
                                    { "name" => "scan", "status" => "completed", "conclusion" => "skipped" },
                                    { "name" => "lint", "status" => "completed", "conclusion" => "neutral" }
                                  ))
    assert_equal :green, v[:state]
    assert_equal 3, v[:count]
  end

  def test_check_runs_none_when_the_sha_has_no_runs
    # THE STATE OF THE WORLD TODAY: ci.yml triggers on pull_request + push:main, so
    # a release-tip SHA has NO check-runs. GitHub answers 200 with an empty list —
    # "no data", never a failure. It stays valid after run-ci-on-release-branch
    # lands (any SHA CI simply never built).
    assert_equal :none, CiStatus.parse_check_runs(check_runs)[:state]
    assert_equal :none, CiStatus.parse_check_runs('{"total_count":0,"check_runs":[]}')[:state]
  end

  def test_check_runs_unverified_on_a_404_or_gh_error_never_a_red
    # An auditor that cannot READ the record reports that — it never invents a red
    # (which would alarm on every un-pushed SHA and every gh outage).
    v = CiStatus.parse_check_runs('{"message":"Not Found","status":"404"}')
    assert_equal :unverified, v[:state]
    assert_equal "Not Found", v[:reason]

    v = CiStatus.parse_check_runs("gh: command not found")
    assert_equal :unverified, v[:state]
    assert_includes v[:reason], "command not found"
  end

  def test_check_runs_reports_a_TRUNCATED_read_rather_than_folding_a_false_green
    # The query asks for one page of 100 (no --paginate: gh emits concatenated JSON
    # documents past page 1 on an OBJECT endpoint, which JSON.parse rejects — the
    # auditor would go silently blind on the BIGGEST suites). So a suite larger than
    # the page must SAY it could not see the whole record: a green fold over a
    # partial list could be hiding a red on the page we never read.
    partial = JSON.generate("total_count" => 120,
                            "check_runs" => [{ "name" => "test", "status" => "completed", "conclusion" => "success" }])
    v = CiStatus.parse_check_runs(partial)
    assert_equal :unverified, v[:state], "a partial read is NO DATA, not a green"
    assert_includes v[:reason], "read only 1 of 120"
  end

  def test_check_runs_a_truncated_read_that_ALREADY_found_a_failure_is_still_red
    # A failure outranks everything, so more runs cannot un-fail it — this partial
    # fold IS trustworthy, and downgrading it to :unverified would throw away a
    # true red.
    partial = JSON.generate("total_count" => 120,
                            "check_runs" => [{ "name" => "test:system", "status" => "completed",
                                               "conclusion" => "failure" }])
    v = CiStatus.parse_check_runs(partial)
    assert_equal :red, v[:state]
    assert_equal ["test:system"], v[:failing]
  end

  def test_check_runs_accepts_a_bare_array_of_runs_too
    v = CiStatus.parse_check_runs('[{"name":"test","status":"completed","conclusion":"failure"}]')
    assert_equal :red, v[:state]
    assert_equal ["test"], v[:failing]
  end

  def test_check_runs_names_an_unnamed_run_by_its_conclusion
    v = CiStatus.parse_check_runs(check_runs({ "status" => "completed", "conclusion" => "failure" }))
    assert_equal ["failure"], v[:failing]
  end

  def test_for_sha_bare_token_short_circuits_the_gh_call
    # The RELEASE_CI_STATUS injection seam — the G3 twin of DOR_CHECK_CI_STATUS.
    # No nwo, no sha, no network: a canned verdict comes straight back.
    assert_equal :green, CiStatus.for_sha("", "", "green")[:state]
    assert_equal :none, CiStatus.for_sha("", "", "none")[:state]

    red = CiStatus.for_sha("o/r", "abc", "red")
    assert_equal :red, red[:state]
    assert_equal ["ci"], red[:failing]

    pending = CiStatus.for_sha("o/r", "abc", "pending")
    assert_equal :pending, pending[:state]
    assert_equal ["ci"], pending[:pending]
  end

  def test_for_sha_accepts_an_injected_check_runs_payload
    v = CiStatus.for_sha("o/r", "abc", check_runs({ "name" => "test", "status" => "completed", "conclusion" => "failure" }))
    assert_equal :red, v[:state]
    assert_equal ["test"], v[:failing]
  end

  def test_for_sha_is_unverified_rather_than_shelling_out_without_a_repo_or_sha
    assert_equal :unverified, CiStatus.for_sha("", "abc123", nil)[:state]
    assert_equal :unverified, CiStatus.for_sha("owner/repo", "", nil)[:state]
  end

  # --- G3 CREDIT (credited_verdict / credit_for_sha) ---------------------------
  #
  # The dedupe probe for a fast-forwarded accepted→release promote (task
  # dedupe-hub-release-suite): the SAME SHA already holds a completed green
  # conclusion, and the release push queued a DUPLICATE run of the same checks.
  # The probe credits ONLY that exact shape; every other answer is nil — "no
  # credit, take the normal poll" — so red/pending/missing handling stays intact.

  def test_credited_verdict_credits_when_every_pending_run_duplicates_a_completed_green
    v = CiStatus.credited_verdict(check_runs(
                                    { "name" => "test", "status" => "completed", "conclusion" => "success" },
                                    { "name" => "test:system", "status" => "completed", "conclusion" => "success" },
                                    { "name" => "test", "status" => "queued", "conclusion" => nil },
                                    { "name" => "test:system", "status" => "in_progress", "conclusion" => nil }
                                  ))
    assert v, "an existing green conclusion whose pending runs are pure duplicates must credit"
    assert_equal :green, v[:state]
    assert_equal 2, v[:count], "count is the CONCLUDED runs, not the duplicates"
    assert_includes v[:credited], "2 completed check-runs already green"
    assert_includes v[:credited], "2 pending runs duplicate them"
  end

  def test_credited_verdict_counts_a_skipped_conclusion_as_a_concluded_counterpart
    # A completed `skipped` run is how the original suite CONCLUDED that check —
    # gh's own fold reads all-pass/skip as green — so a pending duplicate of it is
    # covered. At least one genuine PASS is still required (asserted below).
    v = CiStatus.credited_verdict(check_runs(
                                    { "name" => "test", "status" => "completed", "conclusion" => "success" },
                                    { "name" => "scan", "status" => "completed", "conclusion" => "skipped" },
                                    { "name" => "scan", "status" => "queued", "conclusion" => nil }
                                  ))
    assert v
    assert_equal :green, v[:state]
  end

  def test_credited_verdict_never_credits_a_failure_or_cancel
    # RED STILL BLOCKS, byte-for-byte: any failed/cancelled run refuses the credit,
    # so the caller's normal read aborts exactly as before.
    %w[failure cancelled timed_out action_required].each do |conclusion|
      assert_nil CiStatus.credited_verdict(check_runs(
                                             { "name" => "test", "status" => "completed", "conclusion" => "success" },
                                             { "name" => "test", "status" => "queued", "conclusion" => nil },
                                             { "name" => "e2e", "status" => "completed", "conclusion" => conclusion }
                                           )), "a #{conclusion} run must never be re-read as a credit"
    end
  end

  def test_credited_verdict_never_credits_a_pending_check_with_no_completed_counterpart
    # The ORIGINAL suite still running is a genuine wait, not a duplicate: a
    # half-finished first run must never be folded into a false green.
    assert_nil CiStatus.credited_verdict(check_runs(
                                           { "name" => "test", "status" => "completed", "conclusion" => "success" },
                                           { "name" => "test:system", "status" => "in_progress", "conclusion" => nil }
                                         ))
  end

  def test_credited_verdict_never_credits_an_unnamed_pending_run
    # No name, no way to prove it duplicates a concluded check — conservative nil.
    assert_nil CiStatus.credited_verdict(check_runs(
                                           { "name" => "test", "status" => "completed", "conclusion" => "success" },
                                           { "status" => "queued", "conclusion" => nil }
                                         ))
  end

  def test_credited_verdict_is_nil_when_nothing_is_pending
    # All-completed green is the PLAIN verdict's job — for_sha already answers
    # :green on the first read and no wait happens, so there is nothing to credit.
    assert_nil CiStatus.credited_verdict(check_runs(
                                           { "name" => "test", "status" => "completed", "conclusion" => "success" }
                                         ))
  end

  def test_credited_verdict_requires_at_least_one_genuine_pass
    # An all-skipped "conclusion" proves no suite ever ran — never credit it.
    assert_nil CiStatus.credited_verdict(check_runs(
                                           { "name" => "scan", "status" => "completed", "conclusion" => "skipped" },
                                           { "name" => "scan", "status" => "queued", "conclusion" => nil }
                                         ))
  end

  def test_credited_verdict_is_nil_on_a_truncated_read
    # A partial page could hide a red on the page never read — no credit.
    partial = JSON.generate("total_count" => 120,
                            "check_runs" => [
                              { "name" => "test", "status" => "completed", "conclusion" => "success" },
                              { "name" => "test", "status" => "queued", "conclusion" => nil }
                            ])
    assert_nil CiStatus.credited_verdict(partial)
  end

  def test_credited_verdict_is_nil_on_empty_or_unreadable_payloads
    assert_nil CiStatus.credited_verdict(check_runs), "no runs, no conclusion to credit"
    assert_nil CiStatus.credited_verdict("gh: command not found")
    assert_nil CiStatus.credited_verdict('{"message":"Not Found","status":"404"}')
    assert_nil CiStatus.credited_verdict("")
  end

  def test_credit_for_sha_never_credits_a_bare_injected_token
    # A bare token names a FOLDED state, not runs — no evidence of an existing
    # conclusion. Notably "pending" must keep meaning "hold and poll", and even
    # "green" carries no run record to credit (the plain read passes on its own).
    CiStatus::TOKENS.each do |token|
      assert_nil CiStatus.credit_for_sha("o/r", "abc", token), "token #{token} must not credit"
    end
  end

  def test_credit_for_sha_accepts_an_injected_check_runs_payload
    v = CiStatus.credit_for_sha("o/r", "abc", check_runs(
                                                { "name" => "test", "status" => "completed", "conclusion" => "success" },
                                                { "name" => "test", "status" => "queued", "conclusion" => nil }
                                              ))
    assert v
    assert_equal :green, v[:state]
  end

  def test_credit_for_sha_is_nil_rather_than_shelling_out_without_a_repo_or_sha
    assert_nil CiStatus.credit_for_sha("", "abc123", nil)
    assert_nil CiStatus.credit_for_sha("owner/repo", "", nil)
  end

  def test_name_with_owner_reads_every_github_remote_form
    assert_equal "amcritchie/mcritchie-studio", CiStatus.name_with_owner("git@github.com:amcritchie/mcritchie-studio.git")
    assert_equal "amcritchie/mcritchie-studio", CiStatus.name_with_owner("https://github.com/amcritchie/mcritchie-studio.git")
    assert_equal "amcritchie/mcritchie-studio", CiStatus.name_with_owner("https://github.com/amcritchie/mcritchie-studio")
    assert_equal "amcritchie/turf-monster", CiStatus.name_with_owner("ssh://git@github.com/amcritchie/turf-monster.git\n")
  end

  def test_name_with_owner_is_blank_for_a_non_github_remote
    # → for_sha :unverified (no data), never a red: a repo GitHub doesn't host has
    # no CI verdict to disagree with.
    assert_equal "", CiStatus.name_with_owner("/srv/mirrors/mcritchie-studio.git")
    assert_equal "", CiStatus.name_with_owner("")
  end

  # --- :unreadable — a gate that cannot SEE must say WHY it cannot see ---------
  #
  # THE BUG (task dor-check-misses-rolio-ci, verified 2026-07-13): a PERMISSION
  # denial and a genuinely-un-run CI both collapsed into "no verdict". A blind gate
  # that cannot name its blindness gets ignored, then routed around — and that is
  # how a genuinely RED CI eventually slips through. So an auth/permission failure
  # is its OWN state, carrying its own cause.
  #
  # :unreadable is NOT more lenient than :unverified — it blocks exactly the same
  # routes (notably it does NOT unlock the fast-cert credit). It is more HONEST.

  # The VERBATIM body from `gh pr checks 23 --repo amcritchie/rolio` (2026-07-13):
  # rolio is a PRIVATE repo and the fine-grained PAT lacks Checks: Read on it, so
  # the statusCheckRollup nodes come back denied.
  ROLIO_GRAPHQL_403 = "GraphQL: Resource not accessible by personal access token " \
                      "(node.statusCheckRollup.nodes.0.commit.statusCheckRollup.contexts.nodes.0), " \
                      "Resource not accessible by personal access token " \
                      "(node.statusCheckRollup.nodes.0.commit.statusCheckRollup.contexts.nodes.1)"

  def test_parse_a_permission_denial_is_unreadable_never_none
    # THE REGRESSION. Folding this into :none would be the worst outcome: :none is
    # "the workflow hasn't reported yet", which tells the builder to WAIT for a CI
    # that is already green, and tells pr-review's supervisor to DEFER the wave
    # forever. It must never be :none.
    v = CiStatus.parse(ROLIO_GRAPHQL_403)
    refute_equal :none, v[:state], "a permission denial is not an absent CI"
    assert_equal :unreadable, v[:state]
    assert_includes v[:reason], "not accessible", "the cause must be NAMED, not swallowed"
  end

  def test_check_runs_a_403_is_unreadable_never_a_bare_unverified
    # The VERBATIM body from `gh api repos/amcritchie/<repo>/branches/main/protection`
    # and the check-runs endpoint on a repo the token cannot read: gh prints the JSON
    # error on stdout AND its own line on stderr, and we capture 2>&1 — so the raw
    # text is CONCATENATED and JSON.parse rejects it. Detection must read the RAW
    # body, not just a cleanly-parsed `message`.
    raw = '{"message":"Resource not accessible by personal access token",' \
          '"documentation_url":"https://docs.github.com/rest","status":"403"}' \
          "gh: Resource not accessible by personal access token (HTTP 403)"
    v = CiStatus.parse_check_runs(raw)
    assert_equal :unreadable, v[:state]
    assert_includes v[:reason], "not accessible"
  end

  def test_check_runs_a_clean_json_403_or_401_is_unreadable
    v = CiStatus.parse_check_runs('{"message":"Resource not accessible by integration","status":"403"}')
    assert_equal :unreadable, v[:state]
    assert_equal :permissions, v[:cause]

    v = CiStatus.parse_check_runs('{"message":"Bad credentials","status":"401"}')
    assert_equal :unreadable, v[:state]
    assert_equal "Bad credentials", v[:reason]
    assert_equal :credentials, v[:cause]
  end

  def test_unreadable_remedy_matches_the_actual_denial_cause
    repo = "amcritchie/rolio"

    permissions = CiStatus.parse("GraphQL: Resource not accessible by personal access token")
    assert_equal :permissions, permissions[:cause]
    assert_includes CiStatus.unreadable_remedy(repo, cause: permissions[:cause]), "Checks: Read"

    credentials = CiStatus.parse("gh: Bad credentials (HTTP 401)")
    assert_equal :credentials, credentials[:cause]
    credential_remedy = CiStatus.unreadable_remedy(repo, cause: credentials[:cause])
    assert_includes credential_remedy, "gh auth status"
    refute_includes credential_remedy, "Checks: Read"

    rate_limit = CiStatus.parse("gh: API rate limit exceeded (HTTP 403)")
    assert_equal :rate_limit, rate_limit[:cause]
    rate_remedy = CiStatus.unreadable_remedy(repo, cause: rate_limit[:cause])
    assert_includes rate_remedy, "gh api rate_limit"
    refute_includes rate_remedy, "Checks: Read"

    forbidden = CiStatus.parse("gh: Forbidden (HTTP 403)")
    assert_equal :forbidden, forbidden[:cause]
    forbidden_remedy = CiStatus.unreadable_remedy(repo, cause: forbidden[:cause])
    assert_includes forbidden_remedy, "gh auth status"
    refute_includes forbidden_remedy, "Checks: Read"
  end

  def test_gate_evidence_preserves_unreadable_state_cause_reason_and_repo
    verdict = CiStatus.parse("GraphQL: Resource not accessible by personal access token")
    evidence = CiStatus.gate_evidence(verdict, repo: "amcritchie/rolio")

    assert_equal "unreadable", evidence["state"]
    assert_equal "permissions", evidence["cause"]
    assert_equal "amcritchie/rolio", evidence["repo"]
    assert_includes evidence["reason"], "not accessible"
  end

  def test_a_404_stays_unverified_and_is_NOT_promoted_to_unreadable
    # 404 is genuinely AMBIGUOUS (a SHA that was force-pushed away answers 404 too),
    # so it keeps its old meaning. Only an explicit auth/permission denial — 401/403,
    # "not accessible", "bad credentials" — is :unreadable. Narrow on purpose: a
    # state that cries "fix your token" at every missing SHA would be its own lie.
    assert_equal :unverified, CiStatus.parse_check_runs('{"message":"Not Found","status":"404"}')[:state]
    assert_equal :unverified, CiStatus.parse("gh: command not found")[:state]
  end

  def test_no_checks_reported_is_STILL_none
    # Guard the other direction: the honest "no run yet" must not get swept into
    # :unreadable. :none keeps meaning exactly what it meant.
    assert_equal :none, CiStatus.parse("no checks reported on the 'feat/x' branch")[:state]
    assert_equal :none, CiStatus.parse_check_runs('{"total_count":0,"check_runs":[]}')[:state]
  end

  def test_unreadable_is_an_injectable_token
    # the DOR_CHECK_CI_STATUS / RELEASE_CI_STATUS seam — so every CLI test can drive
    # the unreadable path without a network or a broken token.
    assert_includes CiStatus::TOKENS, "unreadable"
    assert_equal :unreadable, CiStatus.evaluate("https://github.com/x/pull/1", "unreadable")[:state]
    assert_equal :unreadable, CiStatus.for_sha("owner/repo", "abc123", "unreadable")[:state]
  end

  def test_view_verdict_a_permission_denial_is_unreadable
    # `gh pr view` is the FIRST gh call evaluate makes — on a repo the token cannot
    # read, it fails there and must already name the cause rather than degrade.
    v = CiStatus.view_verdict("gh: Resource not accessible by personal access token (HTTP 403)")
    assert_equal :unreadable, v[:state]
  end
end
