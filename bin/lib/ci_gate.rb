# frozen_string_literal: true

# CiGate — the REVIEW GATE-ZERO's CI decision, as a pure function.
#
# Two callers in bin/dor-check ask it: the ordinary gated path, and the EXEMPT
# (doc-only) path, which until /tasks/gate-zero-skips-docs-ci never asked anything
# at all — its short-circuit `exit 0` sat above the allow-list, so a docs PR
# advanced a review on a CI nobody read. The fix gave the exempt path the same
# question to ask; putting the answer HERE is what stops the two from drifting into
# two allow-lists, which is a deny-list with extra steps.
#
# PURE ON PURPOSE. It shells nothing, reads no ENV and touches no board, so the
# gate's decision table is unit-testable without spawning bin/dor-check against a
# fixture — see test/lib/dor_check_exempt_ci_test.rb.
require_relative "ci_status"
require_relative "fast_lane"

module CiGate
  # THE ABSOLUTE COMMANDS THIS GATE'S REFUSALS HAND BACK. These compose bin/dor-check's
  # CI refusals, so they reach exactly the reader remedy-hints-print-bare-paths fixed
  # for the cert refusals next door — a builder or reviewer who may be standing on a
  # satellite or gem desk that carries neither script. Resolved from bin/ (this file's
  # parent) once at load; policy and the desk-vs-hub reasoning: FastLane.remedy_command.
  #
  # THE PURITY NOTE IN THE HEADER STILL HOLDS. Resolution reads the FILESYSTEM
  # (File.executable?) exactly once, at require time, and the verdict functions stay
  # pure: they interpolate two frozen strings and shell nothing.
  FULL_SUITE_CMD = FastLane.remedy_command("full-suite-check", File.expand_path("..", __dir__)).freeze
  TASK_CMD = FastLane.remedy_command("task", File.expand_path("..", __dir__)).freeze

  # The states that mean "CI HAS NO VERDICT TO GIVE" — as opposed to a verdict that is
  # bad (:red), settled-negative (:conflicted / :ci_less), still coming (:pending), or
  # not about a live review target (:closed / :merged). This is the ONLY family a full
  # local cert may stand in for, and membership is deliberately explicit: a state that
  # is not listed here cannot be excused by evidence, it can only be classified.
  #
  # :no_pr IS DELIBERATELY ABSENT, and it is absent from THIS list only — it does record
  # a no-verdict ROW (GATE_ROW_NO_PR). The two memberships are separate questions, which
  # /tasks/no-pr-records-as-fail had to prise apart; the full argument is on
  # GATE_ROW_NO_VERDICT below. In one line: a cert can stand in for missing EVIDENCE
  # about a PR, never for a missing PR.
  CI_NO_VERDICT_STATES = %i[none unreadable unverified].freeze

  # CI IS STILL RUNNING (/tasks/pending-ci-paints-check). The word this arm has written
  # builder-side all along, now a named constant because the card needs to MATCH on it:
  # "pending" was in neither the `running` arm nor GATE_ROW_NO_VERDICT, so it fell to the
  # card's `✓` DEFAULT and an in-flight CI was painted as one that PASSED. Mirrors
  # app/models/gate_run.rb's PENDING_RESULT — this file is a bin/ lib and cannot load a
  # Rails model, the same split RUNNING_RESULT and the no-verdict values already live
  # with — and test/integration/gates_card_pending_ci_test.rb pins the pair.
  #
  # IN-FLIGHT, NOT NO-VERDICT, and the difference is the one GATE_ROW_NO_VERDICT spends
  # its own comment on. Those four say the answer was never GIVEN and prescribe going to
  # find out why. This one says the answer is COMING and prescribes waiting — the same
  # thing GateRun::RUNNING_RESULT says about a cert lane, which is why they share a glyph
  # and a set (GateRun::IN_FLIGHT_RESULTS) rather than this one joining a family whose
  # remedy it does not share.
  #
  # ROLE-CONDITIONAL, UNLIKE EVERY VALUE BELOW IT, and that is not an oversight. The
  # no-verdict four are unconditional because what CI reported is a fact about the READ,
  # not about who asked. Here the two roles are asking DIFFERENT QUESTIONS: review's
  # gate-zero asks "may this PR merge NOW", and an unsettled CI is a legitimate NO
  # (hence "fail"), while the builder asks "is my work certified" before the checks have
  # had time to run, where an unsettled CI is simply not an answer yet. Same world, two
  # honest answers, because two different questions were put to it.
  GATE_ROW_PENDING = "pending"

  # The `result` a `{"sop" => "ci"}` GateRun row carries when GitHub REFUSED the read.
  # Mirrors app/models/gate_run.rb's UNREADABLE_RESULT — this file is a bin/ lib and
  # cannot load a Rails model, the same split RUNNING_RESULT already lives with. The
  # two must stay equal or the gates card falls back to painting this row as a pass;
  # test/integration/gates_card_unreadable_ci_test.rb pins the pair (it is the one
  # test that can load both halves).
  GATE_ROW_UNREADABLE = "unreadable"

  # The other two members of CI_NO_VERDICT_STATES, for the same reason and by the same
  # rule: the row stays 1:1 with the CI state. Until /tasks/refused-review-records-fail
  # both collapsed onto a flat "fail" on a refused review, so the PERMANENT gate history
  # claimed a red-CI bounce for a PR whose CI was never red — :none is "the PR reports no
  # checks YET" (the fix is to WAIT) and :unverified is "`gh` itself fell over" (the fix
  # is to RE-READ). Neither is a verdict; they are two different absences of one.
  #
  # THE NAMES ARE THE ONLY DISCRIMINATOR THESE TWO GET. CiStatus.gate_evidence rides
  # `state`/`cause`/`reason` onto the :unreadable row ALONE, so for these two `result`
  # is the whole record. That is why they cannot share a value: "wait for CI" and
  # "GitHub was unreachable" prescribe different moves, and one honest word for both
  # would make the record uniformly useless instead of uniformly wrong.
  #
  # "no_checks", not "none": `bin/gate show` renders `<sop>:<result>`, and `ci:none`
  # reads as "no ci sop was recorded". "unverified" keeps the word the builder path has
  # always written for this state — it is newly 1:1 and newly glyphed, not newly coined.
  GATE_ROW_NO_CHECKS = "no_checks"
  GATE_ROW_UNVERIFIED = "unverified"

  # THERE IS NO PR TO HAVE A CI (/tasks/no-pr-records-as-fail). A blank devops.pr_url
  # resolves to :no_pr, and until this arm that row was written TWO different wrong ways
  # depending on who asked — the one thing every other member of this table refuses to do:
  #
  #   review role  → "fail"        a red-CI bounce for a PR that does not exist
  #   builder role → "unverified"  collides with the state where `gh` FELL OVER
  #
  # The builder half is the sharper one, and it is the NORMAL path: `bin/dor-check` runs
  # BEFORE the PR exists, so this is the ordinary submit-side state rather than an edge
  # case. It is silent on stdout there by design (the gate re-runs after the push), yet it
  # still wrote a durable row — and "unverified" now carries an INSTRUCTION, added by
  # /tasks/refused-review-records-fail: "`gh` fell over — re-read, do NOT chase a
  # credential." That is precisely the wrong move for a task whose PR simply is not open
  # yet, where the fix is to PUSH ONE. A record that prescribes the wrong move is worse
  # than one that says nothing, which is why this cannot stay on the `else`.
  #
  # ==== WHY IT IS RECORDED AT ALL, WHICH WAS THE REAL QUESTION =================
  #
  # The sharper framing (steffon's, raising this) is not "which value" but whether an
  # absent PR belongs under the `ci` sop at all: :none and :unverified are ANSWERS ABOUT
  # CI, while :no_pr is the ABSENCE OF THE THING CI WOULD ANSWER ABOUT. That is right,
  # and it is why :no_pr is NOT in CI_NO_VERDICT_STATES (see there). It is not why the
  # row should vanish, for three measured reasons:
  #
  #   1. OMISSION IS NOT REACHABLE FROM HERE. Both callers append the row on `if ci`,
  #      not on this method's return (bin/dor-check:3930 and :2777), and `ci` is
  #      `{state: :no_pr}` — truthy. Returning nil persists `"result" => null`, and
  #      `nil.to_s` is "", which falls to the gates card's ✓ DEFAULT. The omission
  #      route's failure mode IS the inversion trap this family exists to stop.
  #   2. ABSENCE IS ALREADY SPOKEN FOR. `--gate build` writes no ci row at all
  #      (bin/dor-check:3101), so a missing row already means "build gate". A second
  #      meaning makes the record LESS legible, not more — and the suite already holds
  #      this principle: gate_record_no_verdict_ci_test's `ci_sop_entry` refuses to
  #      conclude anything from an absent row, because an absent row is not a passing row.
  #   3. THE AUDITOR NEEDS THE WORD. This is the fleet's most common gate run. Omitting
  #      it would leave the normal path indistinguishable from a build gate and from a
  #      run that aborted early. "no_pr" says the true thing in one word, in both roles.
  #
  # "no_pr" keeps the state's own spelling, as "unverified" did: it is newly 1:1 and
  # newly glyphed, not newly coined.
  GATE_ROW_NO_PR = "no_pr"

  # Every row value the no-verdict family can produce. Mirrors app/models/gate_run.rb's
  # NO_VERDICT_RESULTS (the same bin/-lib-cannot-load-a-model split GATE_ROW_UNREADABLE
  # documents above), and the two are pinned equal by
  # test/integration/gates_card_no_verdict_ci_test.rb — the one test that loads both.
  #
  # IT EXISTS SO THE GLYPH ARM IS ONE EDIT, NOT N. The gates card's chain ends in a ✓
  # DEFAULT, so a value that reaches it is painted as a PASS: adding a state here
  # without an arm there converts a manufactured failure into a manufactured success,
  # which is the direction every other defect in this family runs. Add a member to
  # CI_NO_VERDICT_STATES and you owe it an arm below AND an entry here; the
  # distinctness assertion in test/lib/gate_record_no_verdict_ci_test.rb reddens if you
  # skip the arm (the state falls to the `else` and collides with "unverified"), and
  # the equality assertion reddens if you skip the entry.
  #
  # ==== THIS SET IS NOT CI_NO_VERDICT_STATES, AND THE DIFFERENCE IS LOAD-BEARING ====
  #
  # They were 1:1 until /tasks/no-pr-records-as-fail, which is an accident of the three
  # states that arrived first, not a rule. They answer DIFFERENT QUESTIONS:
  #
  #   CI_NO_VERDICT_STATES  is GATE SEMANTICS — "a FULL local cert may stand in for this
  #                         refusal, so the review still ADVANCES."
  #   GATE_ROW_NO_VERDICT   is RENDERING — "this row is neither a pass nor a failure, so
  #                         paint it ⚠ rather than ✓ or ✗."
  #
  # :no_pr is a member of the SECOND and deliberately not the first. Its row is honestly
  # no-verdict (there was no CI to have one), but no cert may excuse it: what is missing
  # is not the EVIDENCE, it is the SUBJECT — review's job is to merge a PR, and a cert
  # cannot conjure one. Admitting it to CI_NO_VERDICT_STATES would let a task with no PR
  # at all advance a review on tier 2 of the allow-list, which is the most dangerous
  # false green this gate could produce; the :no_pr refusal already returns
  # cert_clears = false for exactly this reason. So keep any future member's two
  # memberships decided SEPARATELY, and do not restore an equality between these lists.
  GATE_ROW_NO_VERDICT = [GATE_ROW_NO_CHECKS, GATE_ROW_UNREADABLE, GATE_ROW_UNVERIFIED,
                         GATE_ROW_NO_PR].freeze

  # The review role's refusal for a non-green CI → [message, cert_clears]. Never called
  # for :green (the allow-list's only pass) nor for a state `verdict`'s case below
  # already wrote a remedy for. `cert_clears` marks the no-verdict family, whose refusal a FULL
  # local cert clears — resolved after the suite gate, where suite_eval is known.
  #
  # ==== THE MESSAGE AND THE FLAG COME FROM ONE PARAMETER =======================
  #
  # `cert_route:` decides BOTH what this refusal offers and what the caller is then
  # allowed to accept. That coupling is the fix, not a convenience: the two used to be
  # decided in different files, and they drifted the moment the exempt path arrived.
  #
  # THE DEFECT (/tasks/exempt-refusal-prints-dead-remedy). The exempt caller asked for
  # this refusal, was handed `cert_clears = true` with it, and DISCARDED the flag —
  # correctly, because nothing stands in on that path. But the message it printed had
  # already promised the route the discarded flag was the only thing that could honour.
  # So the gate told the operator "certify in full instead: bin/full-suite-check
  # <slug>", and adding that cert produced a BYTE-IDENTICAL refusal. A remedy the gate
  # cannot honour is worse than a plain no: it teaches people the gate is noise, and an
  # ignored gate is how a genuinely RED CI ships.
  #
  # It cannot recur silently now. `cert_route: false` makes `cert_clears` false AT THE
  # SOURCE, so the caller has nothing to discard, and the same false flows into the
  # text. Changing one without the other means changing this one parameter — and
  # test/lib/dor_check_exempt_ci_test.rb re-derives the promise from the PRINTED
  # refusal and then executes it, in both paths, so a message that outruns its
  # behaviour reddens rather than shipping.
  # `also_refused:` is FORWARDED, NOT DECIDED HERE, for the same reason `cert_route:`
  # is: only the caller knows what ELSE is refusing the verdict this refusal joins.
  # It carries the OTHER live refusals as noun phrases, and the exempt closings below
  # name them instead of promising that a green CI alone would carry the path. See
  # CiStatus.unreadable_remedy's header for why that promise went stale (PR #1225).
  def self.unread_ci_refusal(ci, pr_url, slug, cert_route: true, also_refused: [])
    # THE SHARED FENCE, and it has to be here as well as in CiStatus. This method
    # FORWARDS the route to unreadable_remedy on one branch and BRANCHES ON IT on
    # another (`:none`/`:unverified`) that never reaches that method at all — so a
    # fence living only downstream would leave this branch open to exactly the
    # misspelled symbol it exists to catch. One list, one raise, both entry points.
    CiStatus.validate_cert_route!(cert_route)

    case ci[:state]
    when :unreadable
      # ONE remedy string, not one-and-a-half. unreadable_remedy ALREADY opens with
      # "This is a CREDENTIAL fault or API limit, NOT a missing CI — re-running will
      # never clear it", and ci_status.rb calls it THE ONE REMEDY STRING. Hand-writing
      # that sentence here printed it twice AND dropped the deliberate "or API limit"
      # hedge — which is not a nicety: :rate_limit also produces :unreadable, and a
      # reader told "CREDENTIAL fault" goes and rotates a credential that was fine.
      ["GitHub CI is UNREADABLE (#{ci[:reason]}) — the review gate-zero IS the authoritative CI verdict, and it " \
       "cannot be authoritative about a CI it could not read. " +
       CiStatus.unreadable_remedy(CiStatus.repo_from_pr_url(pr_url), cause: ci[:cause], cert_route: cert_route,
                                  also_refused: also_refused, task: slug),
       cert_route == true]
    when :none, :unverified
      # WAITING IS THE REMEDY, and it is no longer half of one. This branch used to add
      # "or — if this repo has NO workflows at all, where no check will ever appear —
      # certify in full instead", on the premise that solana-studio and turf-vault
      # carried zero workflows. That premise is FALSE and was already corrected in
      # docs/agents/modules/gates/dor.md and pr-review-primary.md (PR #1128); this was
      # the third copy. Re-derived at source 2026-09-05 on `origin/accepted` AND
      # `origin/main`: solana-studio ships .github/workflows/gem-ci.yml, turf-vault
      # ships .github/workflows/ci.yml. "No check will ever appear" is not a property
      # of a repo in this ecosystem — when a check genuinely never arrives it is the
      # PR's MERGE STATE, which ci_status.rb classifies as :conflicted or :ci_less,
      # each with its own remedy and neither clearable by a cert.
      #
      # The cert route survives here only where it is honoured (cert_route), and it is
      # offered as the escape for a wedged verdict, never justified by a repo that has
      # no CI.
      #
      # `== true`, NOT TRUTHINESS, and that is finding (2) of this task's review. While
      # the route was true/false/nil, truthiness and equality agreed. `:retired`
      # (PR #1235) is a TRUTHY value whose entire meaning is that the cert route was
      # retired — so a plain `if cert_route` would offer `bin/full-suite-check` on the
      # one gate that can never honour it, and the tuple below would mark the refusal
      # cert-CLEARABLE besides. Unreachable today (both `verdict` callers pass
      # literals), which is exactly when it is cheap to close.
      cert_escape = if cert_route == true
                      " If checks genuinely cannot settle for this PR, certify in full instead: " \
                        "`#{FULL_SUITE_CMD} #{slug}`, which runs ci.yml's own command (test:system " \
                        "included) locally, and the gate advances on that cert."
                    else
                      # NAME NO SECOND ROUTE. On the exempt path there is none — see
                      # the header. Say what does not work, so nobody spends a
                      # full-suite run discovering it. "no local cert stands in" is
                      # the CONTRACT CLAUSE, spelled identically in
                      # CiStatus.unreadable_remedy's cert_route: false branch: the
                      # regression reads the PRINTED refusal to decide what was
                      # promised, then executes that promise, so the denial needs one
                      # spelling across every state that can carry it.
                      #
                      # THE SUFFICIENCY CLAUSE IS DERIVED for the same reason
                      # unreadable_remedy's is: "Green is the only thing that advances
                      # it" is the SAME promise PR #1225 falsified, in the same role,
                      # on the same path — it is simply reached with a different CI
                      # state. Fixing one closing line and leaving its twin two
                      # branches away would leave this method contradicting itself,
                      # which is the defect family the whole file is about. Empty
                      # prints the original, to the byte.
                      #
                      # BOTH BRANCHES ARE PINNED BY MUTATION, and until
                      # /tasks/fence-the-widened-closing neither was. This derivation
                      # shipped with the twin in CiStatus.unreadable_remedy, whose two
                      # branches ARE fenced; forcing THIS one to print either wording
                      # unconditionally left the suite green at 41 runs / 391 assertions.
                      # A derivation nothing pins is a constant that has not been
                      # noticed yet — so the same deliberate pair now drives
                      # unread_ci_refusal directly AND through bin/dor-check, which is
                      # what hands the list down (see test/lib/dor_check_exempt_ci_test.rb).
                      #
                      # THE CO-FIRE CLAUSE IS INDEPENDENT, not relative, and that is a
                      # correctness fix rather than a preference. It used to end
                      # "..., which green does not clear" — and `also_refused` arrives
                      # as a NOUN PHRASE ending in "the artifact this gate judges", so
                      # the pronoun attached to the ARTIFACT and said green does not
                      # clear the artifact. The twin next door already says it
                      # properly: "..., and no CI result clears that."
                      no_verdict_close = if also_refused.empty?
                                           "Green is the only thing that advances it."
                                         else
                                           "Green is NECESSARY AND NOT SUFFICIENT here: this verdict is " \
                                             "ALSO refused by #{also_refused.join(' AND ')}, and no CI " \
                                             "result clears that."
                                         end
                      " But no local cert stands in for it here: this is the doc-only path, where the " \
                        "shape/test-tier gate is already waived, so there is no suite to substitute — " \
                        "`#{FULL_SUITE_CMD} #{slug}` would leave this refusal unchanged. " \
                        "#{no_verdict_close}"
                    end
      ["GitHub CI has produced no verdict yet (#{ci[:state]}) — the review gate-zero IS the authoritative CI " \
       "verdict, so it must not advance on a CI it has not read. Defer this review until checks appear " \
       "and settle (the supervisor's defer machinery re-queries; a red finish bounces the task back).#{cert_escape}",
       cert_route == true]
    when :no_pr
      # NOT the no-verdict family, and a cert cannot stand in for it: the missing thing
      # is not the evidence, it is the SUBJECT. Review's job is to merge a PR; with a
      # blank pr_url there is nothing to read a verdict from and nothing to merge.
      ["devops.pr_url is BLANK, so the review gate-zero has no PR to read a CI verdict from — and review has " \
       "nothing to merge. Submit-side this is silent on purpose (the gate re-runs after the push); a REVIEW that " \
       "cannot name its PR must not advance the task, which is why this refuses rather than passing quietly. " \
       "Record it: `#{TASK_CMD} update #{slug} --pr-url <url>`.", false]
    else
      # THE POINT OF THE ALLOW-LIST. A state nobody has classified is not evidence of
      # health; it is evidence that this gate is out of date with ci_status.rb.
      #
      # SCOPED TO THE CI STATE, deliberately. This branch used to argue from "the
      # review gate-zero advances on a GREEN CI and nothing else" — the same false
      # sufficiency claim PR #1225 falsified two branches up, borrowed here to justify
      # a refusal that only ever needed NECESSITY. The argument is unchanged and the
      # verdict is unchanged; the sentence now claims only what the allow-list below
      # actually enforces, which is that :green is its sole passing CI STATE. Green
      # does not advance the gate — the shape, tier and PR-read gates each refuse on a
      # fully green CI — and a refusal that overstates its own rule teaches the reader
      # to distrust the next one.
      #
      # ...AND "ADVANCES" WAS STILL THE WRONG VERB (/tasks/gate-prose-overclaims-again).
      # The corrected sentence read "GREEN is the only CI state that advances a review",
      # and that is measurably false. Driven through `bin/dor-check --gate-role review`
      # on a task carrying a FULL cert, :none, :unverified AND :unreadable each reach
      # ready=true exit=0 — THREE non-green states advance a review, by tier 2 below.
      # What :green is alone in is PASSING, the word this comment already used for it.
      # Advancing and passing are different predicates because a cert can waive a
      # refusal, so the sentence now claims the one the allow-list enforces.
      ["GitHub CI reported #{ci[:state].to_s.upcase}, a state this gate does not classify — GREEN is this gate's " \
       "sole PASSING CI state, so an unclassified verdict REFUSES rather than falling through " \
       "to `ready`. Falling through is the bug this allow-list exists to prevent: a blank pr_url once exited 0 " \
       "with no CI line at all. Classify #{ci[:state].inspect} in bin/dor-check's CI gate and in " \
       "bin/lib/ci_status.rb's header, then re-run.", false]
    end
  end

  # THE CI VERDICT, RESOLVED IN ONE PLACE — for the gated path AND the exempt one.
  #
  # It lived inline in bin/dor-check's merge gate, which put it BELOW the exempt-kind
  # short-circuit's `exit 0`: a doc-only diff reached `ready` having never read CI at
  # all (/tasks/gate-zero-skips-docs-ci). Copying the case into the exempt branch
  # would have made two allow-lists to keep in step, and an allow-list that drifts is
  # a deny-list wearing the other one's comments. So both callers ask THIS.
  #
  # Returns [ci_error, cert_clears, notes]:
  #   ci_error    the refusal, or nil to advance
  #   cert_clears whether a FULL local cert may stand in for it (CI_NO_VERDICT_STATES
  #               only, and only where the caller can honour one) — resolved by the
  #               caller, which owns the evidence
  #   notes       non-blocking suggestions the caller folds into its own list
  #
  # `cert_route:` is the CALLER'S OWN ANSWER to "can I honour a cert?", and it governs
  # the refusal TEXT as well as `cert_clears` — see unread_ci_refusal's header. The
  # gated caller passes true; the exempt caller passes false, and gets a refusal that
  # promises nothing it will then refuse. It defaults to true so that adding a third
  # caller cannot silently weaken the gate: `true` is the permissive-message /
  # strict-enough-anyway side, and a caller that cannot honour a cert must say so.
  def self.verdict(ci, review_role:, pr_url:, slug:, cert_route: true, also_refused: [])
    ci_error = nil
    ci_error_cert_clears = false
    notes = []

    # THE CASE BELOW CHOOSES THE REMEDY. THE ALLOW-LIST AFTER IT CHOOSES THE VERDICT.
    # Keep that split: it is the whole fix. This case used to do both, and a case that
    # decides the verdict by naming bad states is a DENY-LIST — unbounded by
    # construction, because every state added to bin/lib/ci_status.rb afterwards
    # defaults to PASS, silently. That is not a hypothetical failure mode; it is how
    # :no_pr got here (see the allow-list's note). So the case now only picks the most
    # specific remedy text we have for a state, and `ready` is decided in exactly one
    # place, by asking for GREEN.
    case ci[:state]
    when :red
      ci_error = "GitHub CI is RED for the PR (#{Array(ci[:failing]).join(", ")}) — a red PR handed to review is the " \
        "#1 blocker class (the local cert doesn't run the browser test:system lane CI does). Fix, push, and re-run " \
        "dor-check once CI is green."
    when :conflicted
      # HARD blocker in BOTH roles, distinct from :pending/:none ("CI still coming",
      # genuinely deferrable): a conflicted PR's CI is never coming, so anything
      # softer strands the task in submitted forever (the PR-#509 stall).
      ci_error = "review's gate-zero would defer this forever while the board looks healthy. " +
        CiStatus.conflicted_remedy(ci)
    when :ci_less
      # The SAME hard-blocker shape as :conflicted, for the case that never reads DIRTY:
      # zero check-runs plus a merge GitHub will not confirm. Softer treatment strands
      # the task exactly like the PR-#509 stall — see the THIRD STATE section in
      # bin/lib/ci_status.rb.
      ci_error = CiStatus.ci_less_remedy(ci)
    when :pending
      if review_role
        ci_error = "GitHub CI is still RUNNING for the PR (#{Array(ci[:pending]).join(", ")}) — not green YET. The " \
          "review gate-zero is the authoritative CI verdict, so defer this review until CI settles (the supervisor's " \
          "defer machinery re-queries); a red finish bounces the task back."
      else
        notes << "GitHub CI is still RUNNING for the PR (#{Array(ci[:pending]).join(", ")}) — not green YET, " \
          "but submit-side this NO LONGER blocks: hand off now. The review gate-zero (bin/pr-review's supervisor + " \
          "the primary's dor-check --gate-role review) holds the authoritative verdict — a red CI bounces the task " \
          "back with the failing checks named, so expect that round-trip if CI fails."
      end
    when :closed, :merged
      ci_error = "the PR is #{ci[:state].to_s.upcase}, not an OPEN review target — `gh pr checks` returns the head " \
        "commit's HISTORICAL checks even on a closed/merged PR, so a green here is NOT a live pass. Reconcile " \
        "devops.pr_url (a stale or already-merged PR?) before advancing to review."
    when :green
      nil # THE ONLY PASS. Named explicitly so the allow-list below reads as exhaustive.
    else
      nil # Every remaining state — named or not — is the allow-list's to refuse.
    end

    # ==== THE REVIEW GATE-ZERO IS AN ALLOW-LIST =================================
    #
    # :green is the ONLY state that PASSES, and the no-verdict family is the ONLY
    # state that a full local cert may stand in for — so a no-verdict state still
    # ADVANCES a review when a cert stands in, on the cert and not on its CI.
    # Everything else refuses — INCLUDING a state this gate has never heard of.
    #
    # WHY THE SHAPE AND NOT JUST THE STATES. The gate used to decide `ready` from a
    # deny-list of spellings (:red, :conflicted, :ci_less, :pending, :closed,
    # :merged) and let everything else fall through to a pass. A deny-list defaults
    # to PASS, so it is unbounded: the reader cannot tell "this state was considered
    # safe" from "nobody updated the list", and each new state silently joins the
    # safe side. That is exactly how :no_pr got here — a blank devops.pr_url resolves
    # to :no_pr, which had no branch and no `else`, so --gate-role review exited 0
    # printing "ready to advance" with NO CI LINE AT ALL: more silent than the
    # unread-verdict bug this gate was written to close. An allow-list defaults to
    # REFUSE, which is what a gate is for; adding a state to ci_status.rb now blocks
    # review until somebody classifies it deliberately.
    #
    # THE THREE TIERS:
    #   1. :green                → advance.
    #   2. CI_NO_VERDICT_STATES  → refuse, UNLESS the task carries a FULL cert AND the
    #                              caller can honour one (`cert_route`). On the exempt
    #                              path it cannot, so tier 2 collapses into tier 3 —
    #                              and the refusal SAYS so rather than offering a cert
    #                              it will not accept.
    #   3. everything else       → refuse, unconditionally.
    if review_role && ci_error.nil? && ci[:state] != :green
      ci_error, ci_error_cert_clears = unread_ci_refusal(ci, pr_url, slug, cert_route: cert_route,
                                                                          also_refused: also_refused)
    end

    [ci_error, ci_error_cert_clears, notes]
  end

  # The CI row the gates card shows for this run. Shared by both paths for the same
  # reason `verdict` is: the exempt path records a gate attempt now, and a second
  # copy of this case is a second thing to forget.
  def self.gate_row(ci, review_role:, review_refused:)
    return nil unless ci

    case ci[:state]
    # A REFUSED REVIEW CANNOT RECORD ITS CI ROW AS "pass", AND :green IS THE ONLY
    # STATE WHERE THAT WAS POSSIBLE. `review_refused` used to be consulted in the
    # `else` alone, so the stale-green refusal — whose whole precondition is
    # `ci[:state] == :green` — set the flag and changed nothing: the gate refused the
    # review (exit 1) while the durable gates-card row and the --json payload both
    # recorded CI as "pass". Measured on the refusing fixture: code=1,
    # ci_gate_result="pass". That is this module's own subject one level down — a
    # green credited for a tree nobody ran — surviving into the record the board
    # renders, and it is why deleting the `ci_review_refused = true` assignment left
    # every integration test green: the line was inert.
    #
    # Scoped to :green because :green is the ONLY state where `review_refused` went
    # unread AND a caller can actually reach it — every other REACHABLE refused state
    # already answers "fail", so this is the narrowest edit that covers the defect and
    # its blast radius is exactly the bug. (Stated with that qualifier on purpose:
    # builder-side :pending returns "pending", not "fail", so the unqualified sentence
    # would be false. It is refused-unreachable, which the next paragraph establishes.)
    #
    # A blanket `return "fail" if review_refused` above the case would be EQUIVALENT,
    # and that is a measured claim, not a guess: mutation-tested 2026-09-07, it survived
    # all three suites. The only branch it could differ on is builder-side :pending
    # ("pending" here, "fail" under the hoist), and that combination is UNREACHABLE —
    # CiGate.verdict records a builder-side :pending as a NOTE, never a ci_error (see
    # the :pending arm above), while every assignment that could set `review_refused`
    # requires either a ci_error or review_role. So no caller can construct it.
    #
    # The narrow form is kept anyway, for auditability rather than behaviour: it puts
    # the answer on the branch it belongs to, where the next reader of the :green row
    # meets it. An earlier draft of this comment claimed the hoist WOULD break
    # builder-side pending. It would not, and the mutation said so — recorded here
    # because a gate that argues from an unverified claim is this file's own subject.
    when :green then review_refused ? "fail" : "pass"
    when :pending then review_role ? "fail" : GATE_ROW_PENDING
    when :red, :conflicted, :ci_less, :closed, :merged then "fail"
    # THE TOKEN EXPIRED; CI DID NOT FAIL. :unreadable means GitHub REFUSED the read
    # (401/403/rate limit) — the gate never saw a verdict at all. It used to fall
    # through to the `else` and record "fail" on a refused review, so the DURABLE
    # GateRun row said `ci:fail` for a PR whose CI was never red. That lands in the
    # task's PERMANENT gate history, where a later auditor reads a red-CI bounce that
    # never happened — and installation tokens expire ~HOURLY BY DESIGN in this fleet,
    # so every gate run straddling an expiry wrote one.
    #
    # It inverts the usual direction, which is why it is worth its own arm: the rest
    # of this table guards against a green credited for work nobody verified, and this
    # one MANUFACTURED a failure.
    #
    # The state is not new and the word is not invented: CiStatus.gate_evidence has
    # ridden `state:"unreadable"` + cause + reason into this very sops entry since
    # PR #865, and /tasks/builder-reads-remedy-twice established UNREADABLE as
    # distinct from no-CI in the refusal prose. Only the `result` — the ONE field
    # `bin/gate show` and the gates card actually render — collapsed it. So this is
    # plumbing an existing state into the headline, not a new vocabulary.
    #
    # UNCONDITIONAL, in both roles, on purpose. "Unreadable" is a fact about the
    # READ, not about who asked, and a role-conditional answer would give one fact
    # two names ("unreadable" in review, "unverified" for the builder) in a record
    # whose whole job is being read later by someone who was not here. Builder-side
    # this REPLACES a "unverified" that the gates card painted as a green ✓, so the
    # same edit closes the mirror-image misreport on that path.
    #
    # `:no_pr` and any state ci_status.rb grows later keep the `else` — a different
    # question was asked and got a different non-answer, and this row must stay 1:1
    # with the CI state.
    when :unreadable then GATE_ROW_UNREADABLE
    # THE SAME FIX, THE OTHER TWO CAUSES (/tasks/refused-review-records-fail). These
    # rode the `else` and so recorded "fail" on a refused review — a red-CI bounce that
    # never happened, written into the artifact that outlives Heroku's log retention.
    # Measured 2026-09-09 through the live chain: :none, :unverified and a genuinely RED
    # CI all persisted the identical `{"sop":"ci","result":"fail"}`.
    #
    # UNCONDITIONAL, in both roles, for the reason :unreadable is: what CI reported is
    # a fact about the READ, not about who asked, and a role-conditional answer gives
    # one fact two names in a record whose whole job is being read later by someone who
    # was not here. Builder-side this also splits a flat "unverified" that named :none
    # wrongly and that the gates card painted with the PASS glyph, so the same edit
    # closes the mirror-image misreport on that path — exactly as :unreadable's did.
    when :none then GATE_ROW_NO_CHECKS
    when :unverified then GATE_ROW_UNVERIFIED
    # THERE IS NO PR, SO THERE IS NO CI (/tasks/no-pr-records-as-fail). The last state
    # riding the `else`, and the only one that took BOTH of its wrong turns: "fail" in
    # review (a red-CI bounce for a PR that does not exist) and "unverified" for the
    # builder (colliding with the state where `gh` fell over, whose recorded remedy —
    # "re-read, do NOT chase a credential" — is the wrong instruction for a task that
    # simply has not pushed a PR yet).
    #
    # UNCONDITIONAL, in both roles, for the reason :unreadable and the other two are:
    # whether a PR exists is a fact about the WORLD, not about who asked, and a
    # role-conditional answer gives one fact two names in a record whose whole job is
    # being read later by someone who was not here. Here that is not a tidiness argument
    # — the two names were "fail" and "unverified", both false, and both already in use
    # for something else.
    #
    # RECORDED, NOT OMITTED, and NOT admitted to CI_NO_VERDICT_STATES. Both halves of
    # that are argued on GATE_ROW_NO_PR; the short form is that the row is honestly
    # no-verdict while the refusal is honestly uncertifiable, so the value is amber and
    # the cert still cannot clear it.
    when :no_pr then GATE_ROW_NO_PR
    else
      # A FAILED dor_review must name CI as the failing SOP when CI is why it failed.
      # Leaving the no-verdict family on a flat "unverified" recorded the card's sole
      # cause as a NOTE — the same asymmetry :pending avoids one line above.
      #
      # WHAT IS LEFT HERE IS NOW ONLY THE UNCLASSIFIED. Every member of
      # CI_NO_VERDICT_STATES has its own arm above, and since
      # /tasks/no-pr-records-as-fail so does :no_pr — which was the last NAMED state on
      # this default, and the one that proved the default is not a safe place to leave a
      # state you have actually thought about (it answered "fail" to a reviewer and
      # "unverified" to a builder, for the same world).
      #
      # So this now serves exactly one population: a state ci_status.rb grows that nobody
      # has classified here yet. That is not the no-verdict family — it is an unread
      # gate, and an allow-list defaults to REFUSE, which is what a gate is for. The
      # right response to landing here is to ADD AN ARM, not to read the value.
      #
      # NOTE THE ASYMMETRY THAT REMAINS, deliberately: an unclassified state still
      # answers "fail"/"unverified", the two words this family spent three tasks taking
      # OUT of honest rows. That is correct for an unknown — a gate that cannot classify
      # a state must not paint it amber and look considered — but it does mean a `fail`
      # here can be an unread gate rather than a red CI. `state` is recorded alongside;
      # read it before calling any `ci:fail` a CI failure.
      review_refused ? "fail" : "unverified"
    end
  end
end
