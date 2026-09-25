# frozen_string_literal: true

# CiGate — the DoR gate's CI decision, as a pure function. Since
# /tasks/dor-reads-settled-ci-verdict it is ALSO the whole suite gate: bin/dor-check
# credits ONE form of suite evidence, a settled GREEN GitHub CI verdict for the PR's
# current head, and this module is where that verdict becomes a pass, a refusal, or
# (builder-side, pending) a WAIT.
#
# Two callers in bin/dor-check ask it: the ordinary gated path, and the EXEMPT
# (doc-only) path, which until /tasks/gate-zero-skips-docs-ci never asked anything
# at all — its short-circuit `exit 0` sat above the allow-list, so a docs PR
# advanced a review on a CI nobody read. Putting the answer HERE is what stops the
# two from drifting into two allow-lists, which is a deny-list with extra steps.
#
# PURE ON PURPOSE. It shells nothing, reads no ENV and touches no board, so the
# gate's decision table is unit-testable without spawning bin/dor-check against a
# fixture — see test/lib/dor_check_exempt_ci_test.rb.
require_relative "ci_status"
require_relative "fast_lane"

module CiGate
  # THE ABSOLUTE COMMAND THIS GATE'S REFUSALS HAND BACK. It composes bin/dor-check's
  # blank-pr_url refusal, so it reaches exactly the reader remedy-hints-print-bare-paths
  # fixed for the cert refusals next door — a builder or reviewer who may be standing
  # on a satellite or gem desk that carries no hub script. Resolved from bin/ (this
  # file's parent) once at load; policy and the desk-vs-hub reasoning:
  # FastLane.remedy_command.
  #
  # THE PURITY NOTE IN THE HEADER STILL HOLDS. Resolution reads the FILESYSTEM
  # (File.executable?) exactly once, at require time, and the verdict functions stay
  # pure: they interpolate one frozen string and shell nothing.
  TASK_CMD = FastLane.remedy_command("task", File.expand_path("..", __dir__)).freeze

  # The one form of suite evidence bin/dor-check credits, named so the --json payload,
  # the gate SOPs and the docs spell it the same way.
  SUITE_EVIDENCE_FORM = "settled-green-ci"

  # THE ONE SENTENCE EVERY REFUSAL BELOW LEANS ON — spelled once, because it is the
  # whole rule and a second spelling is a second thing to keep true. It replaces the
  # cert offers this module used to print ("certify in full instead:
  # bin/full-suite-check <slug>"): there is no local cert that stands in for a CI
  # verdict any more, in either role, on either path.
  ONLY_EVIDENCE = "a settled GREEN GitHub CI for the PR's current head is the ONLY suite evidence " \
                  "this gate credits"

  # The states that mean "CI HAS NO VERDICT TO GIVE" — as opposed to a verdict that is
  # bad (:red), settled-negative (:conflicted / :ci_less), still coming (:pending), or
  # not about a live review target (:closed / :merged). Every member REFUSES in both
  # roles now, with its own remedy: no local cert stands in for any of them since
  # /tasks/dor-reads-settled-ci-verdict. The list is kept because the gates card
  # paints these amber rather than red (GATE_ROW_NO_VERDICT below) and because the
  # remedies differ — "wait, a check is coming" is not "refresh the token".
  #
  # :no_pr IS DELIBERATELY ABSENT, and it is absent from THIS list only — it does record
  # a no-verdict ROW (GATE_ROW_NO_PR). What is missing there is not EVIDENCE about a
  # PR but the PR itself; see GATE_ROW_NO_VERDICT below.
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
  # had time to run, where an unsettled CI is simply not an answer yet — a WAIT, which
  # `verdict` below still refuses (exit 1) but words as waiting rather than failing.
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
  # The row is recorded rather than omitted for three measured reasons: both callers
  # append it on `if ci` and `ci` is `{state: :no_pr}` (truthy), so nil would persist
  # `"result" => null`, which the gates card paints ✓; an absent row already means
  # "build gate"; and the auditor needs the word, because this is the fleet's most
  # common gate run. "no_pr" keeps the state's own spelling.
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
  # THIS SET IS NOT CI_NO_VERDICT_STATES: that one is GATE SEMANTICS (which absences
  # are a READ failure rather than a missing PR), this one is RENDERING (which rows are
  # neither a pass nor a failure, so paint ⚠). :no_pr is a member of the second and
  # deliberately not the first.
  GATE_ROW_NO_VERDICT = [GATE_ROW_NO_CHECKS, GATE_ROW_UNREADABLE, GATE_ROW_UNVERIFIED,
                         GATE_ROW_NO_PR].freeze

  # Is this verdict a WAIT rather than a refusal? Builder-side only, and only for a CI
  # that is genuinely RUNNING: bin/ship holds at step 6/8 for exactly this, so the
  # ordinary handoff never sees it, and a hand-run verdict that does is told to come
  # back rather than told it failed. Review's gate-zero is the authoritative verdict,
  # and an unsettled CI is a legitimate NO there.
  def self.waiting?(ci, review_role:)
    !review_role && ci.is_a?(Hash) && ci[:state] == :pending
  end

  # The refusal for a CI that has NO VERDICT TO GIVE (the no-verdict family, a blank
  # pr_url, and any state this gate has never heard of) — one string, worded for the
  # role that is reading it. Never called for :green (the allow-list's only pass) nor
  # for a state `verdict`'s case below already wrote a remedy for.
  #
  # NO CERT ESCAPE, ANYWHERE. Until /tasks/dor-reads-settled-ci-verdict the review
  # role's copy of this refusal ended by offering `bin/full-suite-check <slug>`, and
  # bin/dor-check then honoured that cert in place of the unread verdict. Both halves
  # are gone: ONLY_EVIDENCE is the rule, and every branch below says so instead.
  #
  # `also_refused:` is FORWARDED, NOT DECIDED HERE: only the caller knows what ELSE is
  # refusing the verdict this refusal joins. It carries the OTHER live refusals as noun
  # phrases, and the closing lines below name them instead of promising that a green CI
  # alone would carry the path. See CiStatus.unreadable_remedy's header for why that
  # promise went stale (PR #1225).
  def self.unread_ci_refusal(ci, pr_url, slug, review_role: true, also_refused: [])
    case ci[:state]
    when :unreadable
      # ONE remedy string, not one-and-a-half. unreadable_remedy ALREADY opens with
      # "This is a CREDENTIAL fault or API limit, NOT a missing CI — re-running will
      # never clear it", and ci_status.rb calls it THE ONE REMEDY STRING. Hand-writing
      # that sentence here printed it twice AND dropped the deliberate "or API limit"
      # hedge — which is not a nicety: :rate_limit also produces :unreadable, and a
      # reader told "CREDENTIAL fault" goes and rotates a credential that was fine.
      lead = if review_role
               "GitHub CI is UNREADABLE (#{ci[:reason]}) — the review gate-zero IS the authoritative CI verdict, " \
                 "and it cannot be authoritative about a CI it could not read. "
             else
               "GitHub CI is UNREADABLE (#{ci[:reason]}) — the token was REFUSED reading it, which is NOT the same " \
                 "as no CI: #{ONLY_EVIDENCE}, and it cannot credit a verdict it could not read. "
             end
      lead + CiStatus.unreadable_remedy(CiStatus.repo_from_pr_url(pr_url), cause: ci[:cause],
                                        also_refused: also_refused, task: slug)
    when :none, :unverified
      if review_role
        # THE SUFFICIENCY CLAUSE IS DERIVED, for the reason unreadable_remedy's is:
        # "Green is the only thing that advances it" is the SAME promise PR #1225
        # falsified, in the same role, on the same path — it is simply reached with a
        # different CI state. EMPTY prints the original, to the byte.
        #
        # THE CO-FIRE CLAUSE IS INDEPENDENT, not relative: `also_refused` arrives as a
        # NOUN PHRASE ending in "the artifact this gate judges", so a trailing "which
        # green does not clear" attached to the ARTIFACT. The twin next door already
        # says it properly: "..., and no CI result clears that."
        no_verdict_close = if also_refused.empty?
                             "Green is the only thing that advances it."
                           else
                             "Green is NECESSARY AND NOT SUFFICIENT here: this verdict is " \
                               "ALSO refused by #{also_refused.join(' AND ')}, and no CI " \
                               "result clears that."
                           end
        "GitHub CI has produced no verdict yet (#{ci[:state]}) — the review gate-zero IS the authoritative CI " \
          "verdict, so it must not advance on a CI it has not read. Defer this review until checks appear " \
          "and settle (the supervisor's defer machinery re-queries; a red finish bounces the task back) — " \
          "no local cert stands in for it: #{ONLY_EVIDENCE}. #{no_verdict_close}"
      elsif ci[:state] == :none
        # THE BUILDER'S HALF OF :none — the seconds after `gh pr ready`, or a workflow
        # that never fired. Waiting is the remedy when the run is coming; a stale base
        # is the one cause that makes it never come, so it is named.
        base = ci[:base].to_s.strip
        rebase = base.empty? ? "merge the PR's base in" : "rebase onto origin/#{base}"
        "GitHub CI has produced no verdict yet (none) — the PR reports no checks, and #{ONLY_EVIDENCE}, so " \
          "there is nothing to advance on and no local cert stands in. Confirm the workflow triggered (a stale base branch runs " \
          "nothing: #{rebase}), then re-run this verdict once it reports — bin/ship waits for exactly this " \
          "at step 6/8 and resumes here."
      else
        # :unverified builder-side — gh missing, a 404, a transport error. NOT a
        # credential refusal, so the credential command fixes nothing and is not named.
        "GitHub CI could not be read (#{ci[:reason].to_s.empty? ? 'gh failed' : ci[:reason]}) — status " \
          "UNVERIFIED. This is NOT a credential refusal (no `gh`, a 404, a transport error), so there is " \
          "nothing to refresh: check `gh pr checks` by hand and re-run this verdict once `gh` answers. " \
          "#{ONLY_EVIDENCE.sub(/\Aa /, 'A ')} — no local cert stands in, and an unread one cannot advance it."
      end
    when :no_pr
      # NOT the no-verdict family: the missing thing is not the evidence, it is the
      # SUBJECT. Review's job is to merge a PR; the builder's is to open one.
      if review_role
        "devops.pr_url is BLANK, so the review gate-zero has no PR to read a CI verdict from — and review has " \
          "nothing to merge. A REVIEW that cannot name its PR must not advance the task, which is why this " \
          "refuses rather than passing quietly. Record it: `#{TASK_CMD} update #{slug} --pr-url <url>`."
      else
        "devops.pr_url is BLANK, so there is no PR to read a CI verdict from — and #{ONLY_EVIDENCE}. Push the " \
          "branch and open the PR (bin/ship does both, then re-runs this verdict), or record an existing " \
          "one: `#{TASK_CMD} update #{slug} --pr-url <url>`."
      end
    else
      # THE POINT OF THE ALLOW-LIST. A state nobody has classified is not evidence of
      # health; it is evidence that this gate is out of date with ci_status.rb. GREEN
      # is this gate's sole PASSING CI state — "passing", not "advancing": the shape,
      # tier and PR-read gates each refuse on a fully green CI, so a refusal that
      # overstates its own rule teaches the reader to distrust the next one.
      "GitHub CI reported #{ci[:state].to_s.upcase}, a state this gate does not classify — GREEN is this gate's " \
        "sole PASSING CI state, so an unclassified verdict REFUSES rather than falling through " \
        "to `ready`. Falling through is the bug this allow-list exists to prevent: a blank pr_url once exited 0 " \
        "with no CI line at all. Classify #{ci[:state].inspect} in bin/lib/ci_gate.rb and in " \
        "bin/lib/ci_status.rb's header, then re-run."
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
  # Returns the refusal (a String), or nil to advance. There is no second value any
  # more: until /tasks/dor-reads-settled-ci-verdict the tuple carried `cert_clears`,
  # the flag that let a FULL local cert stand in for a no-verdict state, and a
  # builder-side :pending travelled as a non-blocking note. Both are retired —
  # ONLY_EVIDENCE is the whole rule, and a note cannot carry a verdict.
  #
  # THE ROLE TABLE, measured by test/lib/dor_check_test.rb:
  #
  #   ci state      builder                       review
  #   green         advances                      advances (unless the base drifted —
  #                                               bin/dor-check's own check)
  #   pending       WAITING — refuses, worded     refuses: defer until CI settles
  #                 as "come back", not "fail"
  #   red           refuses                       refuses
  #   conflicted    refuses                       refuses
  #   ci_less       refuses                       refuses
  #   closed/merged refuses                       refuses
  #   none          refuses (confirm the run)     refuses (defer)
  #   unverified    refuses (re-read gh)          refuses (defer)
  #   unreadable    refuses (the credential)      refuses (the credential)
  #   no_pr         refuses (open the PR)         refuses (record the PR)
  #   anything else refuses (classify it)         refuses (classify it)
  def self.verdict(ci, review_role:, pr_url:, slug:, also_refused: [])
    # THE CASE BELOW CHOOSES THE REMEDY. THE ALLOW-LIST AFTER IT CHOOSES THE VERDICT.
    # Keep that split: it is the whole fix. This case used to do both, and a case that
    # decides the verdict by naming bad states is a DENY-LIST — unbounded by
    # construction, because every state added to bin/lib/ci_status.rb afterwards
    # defaults to PASS, silently. That is not a hypothetical failure mode; it is how
    # :no_pr got here (see the allow-list's note). So the case now only picks the most
    # specific remedy text we have for a state, and `ready` is decided in exactly one
    # place, by asking for GREEN.
    ci_error =
      case ci[:state]
      when :red
        "GitHub CI is RED for the PR (#{Array(ci[:failing]).join(", ")}) — a red PR handed to review is the " \
          "#1 blocker class, and #{ONLY_EVIDENCE}: no local run changes a red. Fix, push, and re-run " \
          "dor-check once CI is green."
      when :conflicted
        # HARD blocker in BOTH roles, distinct from :pending/:none ("CI still coming",
        # genuinely deferrable): a conflicted PR's CI is never coming, so anything
        # softer strands the task in submitted forever (the PR-#509 stall).
        "review's gate-zero would defer this forever while the board looks healthy. " +
          CiStatus.conflicted_remedy(ci)
      when :ci_less
        # The SAME hard-blocker shape as :conflicted, for the case that never reads DIRTY:
        # zero check-runs plus a merge GitHub will not confirm. Softer treatment strands
        # the task exactly like the PR-#509 stall — see the THIRD STATE section in
        # bin/lib/ci_status.rb.
        CiStatus.ci_less_remedy(ci)
      when :pending
        if review_role
          "GitHub CI is still RUNNING for the PR (#{Array(ci[:pending]).join(", ")}) — not green YET. The " \
            "review gate-zero is the authoritative CI verdict, so defer this review until CI settles (the " \
            "supervisor's defer machinery re-queries); a red finish bounces the task back."
        else
          # THE WAIT. Builder-side a running CI used to be a non-blocking note beside a
          # fast cert credited provisionally; with the cert gone there is nothing to
          # credit, so the verdict is not ready — but it is not FAILED either, and the
          # wording says which. bin/dor-check prints this under a WAITING headline when
          # it is the only thing standing.
          "GitHub CI is still RUNNING for the PR (#{Array(ci[:pending]).join(", ")}) — WAITING for it to " \
            "settle. #{ONLY_EVIDENCE.sub(/\Aa /, 'A ')}, so this verdict is not ready YET; nothing about " \
            "the tree is refused. bin/ship waits for exactly this at step 6/8 and resumes here; re-run " \
            "this verdict once the checks report (a red finish is refused, a green one advances)."
        end
      when :closed, :merged
        "the PR is #{ci[:state].to_s.upcase}, not an OPEN review target — `gh pr checks` returns the head " \
          "commit's HISTORICAL checks even on a closed/merged PR, so a green here is NOT a live pass. Reconcile " \
          "devops.pr_url (a stale or already-merged PR?) before advancing to review."
      when :green
        nil # THE ONLY PASS. Named explicitly so the allow-list below reads as exhaustive.
      else
        nil # Every remaining state — named or not — is the allow-list's to refuse.
      end

    # ==== THE GATE IS AN ALLOW-LIST, IN BOTH ROLES ===============================
    #
    # :green is the ONLY state that PASSES. Everything else refuses — INCLUDING a state
    # this gate has never heard of, and INCLUDING the no-verdict family, which a FULL
    # local cert used to stand in for on the review side. That escape is gone
    # (/tasks/dor-reads-settled-ci-verdict): the suite evidence is the CI verdict, so
    # a verdict nobody could read is a verdict this gate does not have.
    #
    # WHY THE SHAPE AND NOT JUST THE STATES. The gate used to decide `ready` from a
    # deny-list of spellings (:red, :conflicted, :ci_less, :pending, :closed,
    # :merged) and let everything else fall through to a pass. A deny-list defaults
    # to PASS, so it is unbounded: the reader cannot tell "this state was considered
    # safe" from "nobody updated the list", and each new state silently joins the
    # safe side. That is exactly how :no_pr got here — a blank devops.pr_url resolves
    # to :no_pr, which had no branch and no `else`, so --gate-role review exited 0
    # printing "ready to advance" with NO CI LINE AT ALL. An allow-list defaults to
    # REFUSE, which is what a gate is for; adding a state to ci_status.rb now blocks
    # both roles until somebody classifies it deliberately.
    if ci_error.nil? && ci[:state] != :green
      ci_error = unread_ci_refusal(ci, pr_url, slug, review_role: review_role, also_refused: also_refused)
    end

    ci_error
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
    # renders.
    #
    # Scoped to :green because :green is the ONLY state where `review_refused` went
    # unread AND a caller can actually reach it — every other REACHABLE refused state
    # already answers "fail" (or its own no-verdict word), so this is the narrowest
    # edit that covers the defect. Builder-side :pending returns "pending", not "fail":
    # it is a WAIT, and the row says so.
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
    # UNCONDITIONAL, in both roles, on purpose. "Unreadable" is a fact about the
    # READ, not about who asked, and a role-conditional answer would give one fact
    # two names in a record whose whole job is being read later by someone who was
    # not here.
    when :unreadable then GATE_ROW_UNREADABLE
    # THE SAME FIX, THE OTHER TWO CAUSES (/tasks/refused-review-records-fail). These
    # rode the `else` and so recorded "fail" on a refused review — a red-CI bounce that
    # never happened, written into the artifact that outlives Heroku's log retention.
    when :none then GATE_ROW_NO_CHECKS
    when :unverified then GATE_ROW_UNVERIFIED
    # THERE IS NO PR, SO THERE IS NO CI (/tasks/no-pr-records-as-fail). Recorded, not
    # omitted, and not admitted to CI_NO_VERDICT_STATES — see GATE_ROW_NO_PR.
    when :no_pr then GATE_ROW_NO_PR
    else
      # WHAT IS LEFT HERE IS ONLY THE UNCLASSIFIED: a state ci_status.rb grows that
      # nobody has classified here yet. That is not the no-verdict family — it is an
      # unread gate, and an allow-list defaults to REFUSE. The right response to
      # landing here is to ADD AN ARM, not to read the value. `state` is recorded
      # alongside; read it before calling any `ci:fail` a CI failure.
      review_refused ? "fail" : "unverified"
    end
  end
end
