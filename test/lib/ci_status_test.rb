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

  # GREEN is the POSITIVE property — EVERY check passed/skipped — not "nothing fail/pending".
  # An UNRECOGNIZED bucket (gh vocabulary drift, a malformed row) is "no verdict yet", never a
  # pass. Mutation evidence: the pre-fix `fold` (green = not-fail-and-not-pending) returned
  # :green here — a fail-open on the dor-check merge gate, asymmetric with the SHA path's
  # check_run_bucket which fail-safes an unknown conclusion to pending.
  def test_an_unrecognized_bucket_is_pending_never_a_green
    assert_equal :pending, CiStatus.parse('[{"name":"x","bucket":"queued"}]')[:state],
                 "an unknown gh bucket must not be invented as a pass"
    assert_equal :pending, CiStatus.parse('[{"name":"a","bucket":"pass"},{"name":"b","bucket":"weird"}]')[:state],
                 "one unrecognized bucket makes the whole fold unsettled, not green"
    assert_equal :red, CiStatus.parse('[{"name":"a","bucket":"fail"},{"name":"b","bucket":"weird"}]')[:state],
                 "a real failure still wins over an unknown bucket"
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

  # --- conflict-remedy-names-wrong-branch (round 5): the base is HOSTILE ---------
  # base = the GitHub PR's baseRefName. pr-review and dor-check interpolate it VERBATIM
  # into task feedback a human then PASTES INTO A SHELL, so the property under test IS
  # the injection property — asserted on the EFFECT (what parses out of the printed
  # line), never on one spelling of the output. A base that is not a plain git ref must
  # NEVER surface as a LIVE shell token in a runnable `git …` line: the commands are
  # omitted (an honest gap), or at most the ref appears shell-escaped and inert. A
  # spelling assertion (refute the literal "; rm") would pass the instant an attacker
  # picks a metacharacter the author did not enumerate; asserting the EFFECT catches
  # every vector, including the ones we did not imagine.

  # A base carrying any of these can, unescaped, run a SECOND command, open a
  # substitution, split into a second argument, or be read as a git/ssh OPTION.
  HOSTILE_BASES = [
    "; rm -rf ~",       # command separator
    "$(touch pwned)",   # $() substitution
    "`id`",             # backtick substitution
    "a b",              # whitespace → two arguments
    "a|b",              # pipe
    "a&&b",             # AND-chain a second command
    "a>b",              # output redirection
    "--upload-pack=x",  # leading dash → git/ssh reads it as an OPTION
    "..",               # range / parent-traversal refspec, never a branch
    ""                  # nothing resolved at all
  ].freeze

  # Both remedies that interpolate a base into a runnable `git merge origin/<base>`,
  # keyed by name so a failure says WHICH sibling regressed.
  def base_remedies(base)
    v = { base: base, merge_state: "DIRTY", mergeable: "CONFLICTING" }
    { "conflicted_remedy" => CiStatus.conflicted_remedy(v),
      "ci_less_remedy"    => CiStatus.ci_less_remedy(v) }
  end

  # THE EFFECT, asserted two ways so it holds whether the impl OMITS the commands or
  # escapes the ref to an inert token — it certifies safety, not the strategy.
  def assert_no_injectable_command(remedy, base, label)
    # (1) The raw external value never reaches the runnable argument position — the
    #     exact defect the blocker named. Stays true under a future switch to
    #     shell-escaping, because the escaped form differs from the raw one.
    refute_includes remedy, "origin/#{base}",
                     "#{label}: unescaped base #{base.inspect} reached a runnable `git merge origin/<base>`"
    # (2) No copy-paste-runnable git line carries a character that could start a second
    #     command or a substitution. The legit lines (`git fetch origin`, `git merge
    #     origin/<ref>`) contain none of these, so this never false-fires on a valid
    #     ref — only an injected payload that survived into a command line trips it.
    remedy.each_line do |line|
      next unless line =~ /\A\s*git\b/

      refute_match(/[;&|`$(){}<>\\'"]/, line,
                   "#{label}: a runnable git line carries a shell-active char for base #{base.inspect}: #{line.inspect}")
    end
  end

  def test_a_hostile_base_never_reaches_a_runnable_command_in_either_remedy
    HOSTILE_BASES.each do |base|
      base_remedies(base).each do |label, remedy|
        assert_no_injectable_command(remedy, base, label)
        # And it still tells the reader what is missing rather than emitting a broken line.
        assert_match(/base/i, remedy, "#{label}: must still name the unresolved base for #{base.inspect}")
      end
    end
  end

  def test_a_normal_base_names_origin_accepted_and_reads_cleanly_in_both_remedies
    base_remedies("accepted").each do |label, remedy|
      assert_match(%r{git merge origin/accepted\b}, remedy, "#{label}: must name the PR's real base")
      remedy.each_line do |line|
        next unless line =~ /\A\s*git\b/

        refute_match(/[;&|`$(){}<>\\'"]/, line, "#{label}: a normal base must produce a clean, inert command line")
      end
    end
  end

  # The predicate itself, at the property grain — a safe ref is exactly a plain git
  # ref, and every shell-active or option-like shape is rejected.
  def test_safe_git_ref_accepts_plain_refs_and_rejects_everything_dangerous
    %w[accepted release main feat/foo v1.2.3 a-b_c].each do |ref|
      assert CiStatus.safe_git_ref?(ref), "#{ref.inspect} is a plain git ref and must be allowed"
    end
    (HOSTILE_BASES + ["-x", "a\nb", "a..b"]).each do |ref|
      refute CiStatus.safe_git_ref?(ref), "#{ref.inspect} is not a plain git ref and must be rejected"
    end
  end

  # [integration] The SAME fix must land in BOTH callers — neither bin/pr-review nor
  # bin/dor-check may hardcode the conflict cure's branch; both route through
  # CiStatus.conflicted_remedy so one PR cannot collect three cures (the ci_less lesson).
  def test_pr_review_and_dor_check_do_not_hardcode_the_conflict_branch
    %w[pr-review dor-check].each do |bin|
      src = File.read(File.expand_path("../../bin/#{bin}", __dir__))
      # Catch the CLASS, not one spelling: `git merge origin/release`, `merge
      # release into the branch`, `rebase on release`, `rebase onto release` — all
      # name the wrong branch (feature PRs target accepted). The narrow guard
      # missed the second AND third spellings in earlier rounds — the very lesson,
      # so this asserts the whole (rebase|merge)…release family. `accepted→release`
      # (the sweep promotion) is NOT a rebase/merge onto release, so it's safe.
      refute_match(%r{(?:rebase|merge)\s+(?:on\s+|onto\s+|origin/)?release\b}, src,
                   "bin/#{bin} must not tell a builder to rebase/merge RELEASE for a conflict — the base is the PR's own")
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

  # A completed run whose conclusion GitHub adds LATER (one we do not map) is "no verdict
  # yet" — never invented as a pass or a fail. The `CHECK_RUN_BUCKETS.fetch(_, "pending")`
  # default IS this guard; pin it, because GitHub extending its conclusion vocabulary is a
  # WHEN not an IF. Mutation evidence: change the fetch default to "pass" and, without this
  # test, nothing goes red — the G3 auditor would invent a green from an unknown conclusion.
  def test_check_runs_an_unmapped_conclusion_is_pending_never_a_green
    v = CiStatus.parse_check_runs(check_runs(
                                    { "name" => "test", "status" => "completed", "conclusion" => "future_state" }
                                  ))
    assert_equal :pending, v[:state], "an unknown completed conclusion is no verdict, never a pass"
    # A known green alongside an unmapped conclusion is still unsettled — the unknown holds it.
    mixed = CiStatus.parse_check_runs(check_runs(
                                        { "name" => "test", "status" => "completed", "conclusion" => "success" },
                                        { "name" => "e2e", "status" => "completed", "conclusion" => "brand_new" }
                                      ))
    assert_equal :pending, mixed[:state]
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

  # The invariant is `pending.all?` (EVERY pending run duplicates a concluded pass), not
  # `.any?`. A MIXED pending set — one duplicate of a concluded check AND one genuinely-new
  # in-flight check — must NOT credit; the new run is the original suite still working.
  # Mutation evidence: with `all?` weakened to `any?` this credits :green (the single-
  # pending tests above can't tell them apart — for one pending run all? ≡ any?).
  def test_credited_verdict_never_credits_a_mixed_pending_set_with_a_genuinely_new_run
    assert_nil CiStatus.credited_verdict(check_runs(
                                           { "name" => "test", "status" => "completed", "conclusion" => "success" },
                                           { "name" => "test", "status" => "queued", "conclusion" => nil },        # duplicate of the concluded pass
                                           { "name" => "e2e",  "status" => "in_progress", "conclusion" => nil }    # NO concluded counterpart — still running
                                         )),
               "a pending run with no concluded counterpart, mixed in with a covered one, is a real wait"
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
    assert_equal "McRitchie-Studio/mcritchie-studio", CiStatus.name_with_owner("git@github.com:McRitchie-Studio/mcritchie-studio.git")
    assert_equal "McRitchie-Studio/mcritchie-studio", CiStatus.name_with_owner("https://github.com/McRitchie-Studio/mcritchie-studio.git")
    assert_equal "McRitchie-Studio/mcritchie-studio", CiStatus.name_with_owner("https://github.com/McRitchie-Studio/mcritchie-studio")
    assert_equal "McRitchie-Studio/turf-monster", CiStatus.name_with_owner("ssh://git@github.com/McRitchie-Studio/turf-monster.git\n")
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

  # The VERBATIM body from `gh pr checks 23 --repo McRitchie-Studio/rolio` (2026-07-13):
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
    # The VERBATIM body from `gh api repos/McRitchie-Studio/<repo>/branches/main/protection`
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
    repo = "McRitchie-Studio/rolio"

    permissions = CiStatus.parse("GraphQL: Resource not accessible by personal access token")
    assert_equal :permissions, permissions[:cause]
    assert_includes CiStatus.unreadable_remedy(repo, cause: permissions[:cause]), "Checks: Read"

    credentials = CiStatus.parse("gh: Bad credentials (HTTP 401)")
    assert_equal :credentials, credentials[:cause]
    credential_remedy = CiStatus.unreadable_remedy(repo, cause: credentials[:cause])
    # The remedy must name a recovery that RUNS in the configuration the docs create.
    # This assertion used to demand `bin/gh-token | gh auth login -h github.com
    # --with-token`, and that is how a broken instruction survived: `gh` REFUSES that
    # pipeline outright whenever GH_TOKEN is set ("The value of the GH_TOKEN
    # environment variable is being used for authentication", exit 1, keyring
    # untouched), and the docs tell every agent to export GH_TOKEN. A test that
    # asserts a string is present cannot notice that the string does not work, so the
    # guard below is now two-sided.
    assert_includes credential_remedy, "bin/gh-auth-refresh"
    refute_includes credential_remedy, "| gh auth login",
                    "piping a token into `gh auth login` is refused whenever GH_TOKEN is set"
    # And the liveness probe must be one an App token can actually answer.
    assert_includes credential_remedy, "gh api rate_limit"
    refute_includes credential_remedy, "Checks: Read"

    authentication = CiStatus.unreadable_remedy(repo, cause: :authentication)
    assert_includes authentication, "bin/gh-auth-refresh"
    refute_includes authentication, "| gh auth login"

    rate_limit = CiStatus.parse("gh: API rate limit exceeded (HTTP 403)")
    assert_equal :rate_limit, rate_limit[:cause]
    rate_remedy = CiStatus.unreadable_remedy(repo, cause: rate_limit[:cause])
    assert_includes rate_remedy, "gh api rate_limit"
    refute_includes rate_remedy, "Checks: Read"

    forbidden = CiStatus.parse("gh: Forbidden (HTTP 403)")
    assert_equal :forbidden, forbidden[:cause]
    forbidden_remedy = CiStatus.unreadable_remedy(repo, cause: forbidden[:cause])
    assert_includes forbidden_remedy, "gh api rate_limit"
    refute_includes forbidden_remedy, "Checks: Read"
  end

  # ADVICE IS A FAILURE-PATH ARTIFACT: this text is read ONLY by someone already
  # blocked, so a command it names that does not exist (renamed, never written,
  # typo'd) wastes the one instruction they get. Assert the PROPERTY across every
  # cause, rather than spot-checking one spelling — spot-checking a spelling is how
  # the previous, non-functional remedy stayed green for a week.
  ALL_REMEDY_CAUSES = [:permissions, :credentials, :authentication, :rate_limit, :forbidden, nil].freeze

  def test_every_command_the_remedy_names_actually_exists
    root = File.expand_path("../..", __dir__)

    ALL_REMEDY_CAUSES.each do |cause|
      text = CiStatus.unreadable_remedy("McRitchie-Studio/rolio", cause: cause)

      text.scan(%r{\bbin/[a-z0-9][a-z0-9._-]*}).uniq.each do |rel|
        path = File.join(root, rel)
        assert File.exist?(path), "remedy for #{cause.inspect} names #{rel}, which does not exist"
        assert File.executable?(path), "remedy for #{cause.inspect} names #{rel}, which is not executable"
      end
    end
  end

  # The specific shape that failed: no remedy may tell a blocked agent to pipe a
  # token into `gh auth login`, which `gh` refuses whenever GH_TOKEN is set.
  def test_no_remedy_prescribes_a_command_gh_refuses
    ALL_REMEDY_CAUSES.each do |cause|
      text = CiStatus.unreadable_remedy("McRitchie-Studio/rolio", cause: cause)

      refute_match(/\|\s*gh auth login/, text,
                   "remedy for #{cause.inspect} prescribes a pipeline gh refuses under GH_TOKEN")
    end
  end

  def test_gate_evidence_preserves_unreadable_state_cause_reason_and_repo
    verdict = CiStatus.parse("GraphQL: Resource not accessible by personal access token")
    evidence = CiStatus.gate_evidence(verdict, repo: "McRitchie-Studio/rolio")

    assert_equal "unreadable", evidence["state"]
    assert_equal "permissions", evidence["cause"]
    assert_equal "McRitchie-Studio/rolio", evidence["repo"]
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

  # --- THE STALE-CREDENTIAL RETRY ---------------------------------------------
  #
  # These are the only tests in this file that RUN the gh reads instead of feeding
  # `parse` a payload, and that is the point: the bug being fixed was a branch that
  # no test could reach, so a test that stubs the verdict proves nothing about it.
  # Both seams are stubs — CI_STATUS_GH_BIN for gh, GH_AUTH_TOKEN_BIN for the token
  # broker — so no network, no real token, and no 1Password session is involved.
  #
  # The stub gh REFUSES exactly as GitHub does on an expired installation token
  # ("Bad credentials (HTTP 401)" on stderr, exit 1) unless it finds the minted token
  # in its OWN environment. Passing therefore requires the whole chain: classify the
  # refusal → mint once → hand the token to the RETRIED CHILD → re-read.

  MINTED = "stub-minted-token"

  def test_a_stale_ambient_credential_is_recovered_and_returns_a_REAL_verdict
    # THE REGRESSION. Before this wiring, an expired ambient credential made every
    # CI read :unreadable — withholding the fast cert from the builder and, worse,
    # blinding the REVIEW gate's authoritative verdict where nobody re-reads it.
    with_gh_stubs(mode: "auth") do |calls, mints|
      v = CiStatus.evaluate("https://github.com/McRitchie-Studio/rolio/pull/23")

      assert_equal :green, v[:state],
                   "a stale ambient credential must be recovered into a REAL verdict, not :unreadable"
      assert_equal 1, File.readlines(mints).size, "exactly ONE mint"
      # view refused → retried; checks then rode the memoized token on its FIRST try.
      assert_equal 3, File.readlines(calls).size, "view (refused) + view (retried) + checks"
    end
  end

  def test_the_pre_fix_behaviour_is_what_this_test_would_otherwise_see
    # THE CONTROL, and the reason the test above is credible: with the broker
    # unavailable the retry cannot complete, and the SAME stub reproduces the exact
    # failure this task was filed for. If the wiring above were deleted, the test
    # above would produce THIS. gh's ORIGINAL refusal survives — untranslated.
    with_gh_stubs(mode: "auth", broker: :broken) do |_calls, mints|
      v = CiStatus.evaluate("https://github.com/McRitchie-Studio/rolio/pull/23")

      assert_equal :unreadable, v[:state]
      assert_equal :credentials, v[:cause]
      assert_includes v[:reason], "Bad credentials"
      assert_equal 1, File.readlines(mints).size, "it TRIED once, then reported gh's own error"
    end
  end

  def test_a_RED_ci_never_mints_even_though_gh_exits_non_zero
    # THE NARROWNESS, and the trap a naive "retry on failure" falls into: `gh pr
    # checks` exits NON-ZERO on a red or pending PR while printing perfectly good
    # JSON. Retrying on exit STATUS would mint a token for every red PR in the fleet
    # and hide the failure behind a credential story. Only the SHAPE of the refusal
    # may trigger a mint.
    with_gh_stubs(mode: "red") do |_calls, mints|
      v = CiStatus.evaluate("https://github.com/McRitchie-Studio/rolio/pull/23")

      assert_equal :red, v[:state]
      assert_equal ["CI"], v[:failing]
      assert_equal 0, File.size(mints), "a red CI is not a credential fault — no mint"
    end
  end

  def test_a_non_auth_error_is_returned_untouched
    # A 404 re-read with a fresh token just 404s again, slower — and the caller must
    # still see GitHub's real words rather than a manufactured credential story.
    with_gh_stubs(mode: "notfound") do |_calls, mints|
      v = CiStatus.evaluate("https://github.com/McRitchie-Studio/rolio/pull/23")

      assert_equal :unverified, v[:state]
      assert_includes v[:reason], "Could not resolve to a PullRequest"
      assert_equal 0, File.size(mints), "not an auth failure — no mint"
    end
  end

  def test_the_sha_addressed_release_read_shares_the_same_recovery
    # for_sha serves the G3 release gate, whose subject (a release tip) belongs to no
    # PR — the read LEAST likely to have a human watching when the credential lapses.
    # It was the third unwired call site, and is wired through the same seam.
    with_gh_stubs(mode: "auth") do |_calls, mints|
      v = CiStatus.for_sha("McRitchie-Studio/rolio", "abc123")

      assert_equal :green, v[:state]
      assert_equal 1, File.readlines(mints).size
    end
  end

  def test_the_minted_token_never_appears_in_the_returned_body
    # It rides the child's ENVIRONMENT. A token that leaks into a verdict reaches the
    # task record, the gate output, and the transcript.
    with_gh_stubs(mode: "auth") do |_calls, _mints|
      v = CiStatus.evaluate("https://github.com/McRitchie-Studio/rolio/pull/23")
      refute_includes v.inspect, MINTED
    end
  end

  def test_one_mint_per_process_not_one_per_call
    with_gh_stubs(mode: "auth") do |_calls, mints|
      3.times { CiStatus.evaluate("https://github.com/McRitchie-Studio/rolio/pull/23") }
      assert_equal 1, File.readlines(mints).size, "the memo holds across calls"
    end
  end

  # --- gh_read_status: the same read, with its OUTCOME ------------------------
  # Every reader INSIDE this file classifies the body and never needs the exit
  # status. bin/dor-check's PR file-list read does: its `--jq` output is a bare list
  # of paths, so an empty body means "the PR changed nothing" on success and "the
  # token was refused" on failure — indistinguishable without `ok`. That gate used to
  # own a private gh call for exactly this reason and silently graded the local git
  # diff whenever the read failed; these pin the seam it now shares.

  def test_gh_read_status_reports_the_failure_gh_reported
    with_gh_stubs(mode: "auth", broker: :broken) do |_calls, _mints|
      body, ok = CiStatus.gh_read_status("api", "repos/o/r/pulls/1/files")

      refute ok, "a refused read must be reported as a FAILED read, not an empty one"
      assert_includes body, "Bad credentials", "stderr rides in the body, or nothing can classify it"
      assert_equal :credentials, CiStatus.unreadable_cause(body)
    end
  end

  def test_gh_read_status_reports_success_after_the_recovery_retry
    # The retried read's OWN outcome is what comes back — not the refusal that
    # triggered the mint. Returning the first attempt's `false` here would make a
    # SUCCESSFUL recovery look like a failure to every caller that reads the status.
    with_gh_stubs(mode: "auth") do |_calls, mints|
      body, ok = CiStatus.gh_read_status("pr", "checks", "https://github.com/McRitchie-Studio/rolio/pull/23",
                                         "--json", "name,state,bucket")

      assert ok, "the recovered read succeeded; its status must say so"
      assert_includes body, "bucket"
      assert_equal 1, File.readlines(mints).size
    end
  end

  def test_gh_read_still_returns_the_body_alone
    # Its callers in this file are unchanged by the split — gh_read is now a
    # projection of gh_read_status, and a String is what they parse.
    with_gh_stubs(mode: "auth", broker: :broken) do |_calls, _mints|
      assert_kind_of String, CiStatus.gh_read("api", "repos/o/r/pulls/1/files")
    end
  end

  def test_a_missing_gh_is_unverified_and_never_a_mint
    # ENOENT is not a refusal. It must stay the :unverified it has always been —
    # `gh: command not found` never meant "your token is stale".
    with_gh_stubs(mode: "auth", gh: "/nonexistent/gh-does-not-exist") do |_calls, mints|
      assert_equal :unverified, CiStatus.evaluate("https://github.com/McRitchie-Studio/rolio/pull/23")[:state]
      assert_equal 0, File.size(mints)
    end
  end

  private

  # Stubs both seams and runs the block with (gh-call-log, mint-call-log). Restores
  # ENV and the memoized token afterwards — module state outlives one example, and a
  # leaked token would silently green the next test.
  def with_gh_stubs(mode:, broker: :working, gh: nil)
    Dir.mktmpdir do |dir|
      calls = File.join(dir, "gh-calls.log")
      mints = File.join(dir, "mint-calls.log")
      [calls, mints].each { |f| File.write(f, "") }

      gh_stub = write_script(dir, "gh-stub", <<~SH)
        #!/bin/sh
        echo "gh $*" >> "$GH_STUB_CALLS"
        if [ "$GH_STUB_MODE" = "notfound" ]; then
          echo 'gh: Could not resolve to a PullRequest with the number of 23. (HTTP 404)' >&2
          exit 1
        fi
        if [ "$GH_STUB_MODE" = "red" ]; then
          # `gh pr checks` prints valid JSON and exits NON-ZERO when a check failed.
          if [ "$2" = "checks" ]; then
            echo '[{"name":"CI","state":"FAILURE","bucket":"fail"}]'
            exit 1
          fi
        elif [ "$GH_TOKEN" != "$GH_STUB_TOKEN" ]; then
          echo 'gh: Bad credentials (HTTP 401)' >&2
          exit 1
        fi
        case "$2" in
          view) echo '{"state":"OPEN","mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","baseRefName":"accepted"}' ;;
          checks) echo '[{"name":"CI","state":"SUCCESS","bucket":"pass"}]' ;;
          *) echo '{"total_count":1,"check_runs":[{"name":"CI","status":"completed","conclusion":"success"}]}' ;;
        esac
        exit 0
      SH

      broker_stub = if broker == :broken
                      write_script(dir, "broker-stub", <<~SH)
                        #!/bin/sh
                        echo "mint $*" >> "$GH_MINT_CALLS"
                        echo 'no 1Password session' >&2
                        exit 1
                      SH
                    else
                      write_script(dir, "broker-stub", <<~SH)
                        #!/bin/sh
                        echo "mint $*" >> "$GH_MINT_CALLS"
                        printf '%s' "$GH_STUB_TOKEN"
                      SH
                    end

      with_env(
        "CI_STATUS_GH_BIN" => gh || gh_stub,
        "GH_AUTH_TOKEN_BIN" => broker_stub,
        "GH_STUB_CALLS" => calls,
        "GH_MINT_CALLS" => mints,
        "GH_STUB_MODE" => mode,
        "GH_STUB_TOKEN" => MINTED,
        # The stale ambient credential itself — set explicitly so the test does not
        # depend on whatever the developer's shell happens to be carrying.
        "GH_TOKEN" => "stale-ambient-token"
      ) do
        CiStatus.reset_gh_auth!
        begin
          yield(calls, mints)
        ensure
          CiStatus.reset_gh_auth!
        end
      end
    end
  end

  def write_script(dir, name, body)
    path = File.join(dir, name)
    File.write(path, body)
    File.chmod(0o755, path)
    path
  end

  def with_env(vars)
    previous = vars.keys.to_h { |k| [k, ENV[k]] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    previous.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
