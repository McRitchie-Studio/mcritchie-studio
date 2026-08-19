# frozen_string_literal: true

module Review
  # Executes an ARMED MERGE — a reviewer's already-recorded merge-ready verdict —
  # after the reviewer's process is gone. See ReviewPendingAction for why this
  # exists (seven lost executions in one night) and for the line this code must
  # not cross: it never FORMS a verdict, it only carries out one already given.
  #
  # EVERY GUARD FAILS CLOSED, and the guards are ordered cheap-first so a routine
  # trigger (a CI run settling on some unrelated branch) costs a couple of indexed
  # reads and no network at all:
  #
  #   1. still pending            — a settled action never runs twice, and (at the
  #                                 write, where a race can actually be settled)
  #                                 never has its outcome overwritten
  #   2. not expired              — a stale order is DROPPED, never executed late
  #   3. task still exists        — nothing to merge into otherwise
  #   4. verdict still recorded   — a WITHDRAWN decision stops authorising
  #   5. verdict not superseded   — a REVISED decision stops authorising
  #   6. destination is authorised— this action type merges to `accepted`, only
  #   7. task still `submitted`   — someone else already moved it
  #   8. no LIVE reviewer         — if a reviewer is awake, it does its own merge
  #   9. CI concluded GREEN       — red / pending / cancelled / ABSENT all do nothing
  #  10. that green is FOR THE PIN— the CI we hold must describe the reviewed tree
  #  11. live PR head == the pin  — the tree must still BE the reviewed tree
  #  12. PR open, based right, and mergeable — a CONFLICTING PR is refused
  #  13. GitHub re-checks the pin — `sha:` on the merge API; 409 if it moved
  #
  # Guards 9 and 10 are why "no checks reported" cannot slip through. A CONFLICTING
  # PR stops GitHub Actions firing ENTIRELY rather than going red, so its checks
  # read as absent; Ci::ReviewGate folds absent check-runs to :none, and :none is
  # not :green. Guard 12 then names the real cause instead of letting it look like
  # a slow lane.
  #
  # Guards 10, 11 and 13 are three independent readings of ONE rule — the verdict
  # described a specific tree. They can disagree (CI can lag a push; a push can
  # land between our read and our write), and the disagreement is the point: any
  # one of them dissenting stops the merge.
  #
  # Guard 5 is the MIRROR of that rule and belongs beside it: the tree pin exists
  # because the TREE may have changed since the verdict; guard 5 exists because the
  # VERDICT may have changed since the tree. Both are re-read HERE, at fire time,
  # rather than enforced when the world changes — a guard in the executor cannot be
  # bypassed by some future path that writes a scout report (or pushes a commit)
  # without knowing an armed merge exists.
  class PendingActionExecutor
    # :executed        — merged, stamped, and moved to `reviewed`
    # :waiting         — nothing is wrong yet; conditions are not met. Stays pending.
    # :refused         — this action can never be right. Settled, terminal.
    # :expired         — its window closed. Settled, terminal.
    # :error           — an unexpected failure. Stays pending so a retry can succeed.
    # :already_settled — a sibling execution settled this row; this run WROTE
    #                    NOTHING and says what it would have written.
    #
    # The last one is a status of its own precisely because it wrote nothing: the
    # four above are claims about what the record now says.
    Result = Struct.new(:status, :reason, :action, keyword_init: true) do
      def executed? = status == :executed
      def waiting?  = status == :waiting
    end

    # A `merge-ready` verdict authorises a merge of the reviewed tree at the seam
    # the reviewer was standing at. Anywhere else, the order does not apply.
    AUTHORISED_FROM_STAGE = "submitted"

    def self.call(action, **kwargs)
      new(action, **kwargs).call
    end

    def initialize(action, now: Time.current, client: nil, logger: Rails.logger)
      @action = action
      @now = now
      @client = client
      @logger = logger
    end

    def call
      # A short serialization point, NOT a lock held across the network calls
      # below: at forty concurrent tasks, forty jobs each pinning a Postgres
      # connection through a multi-second GitHub round trip would exhaust the
      # board's 20-connection pool. Correctness does not rest on this lock —
      # GitHub's own `sha` pin (guard 13) makes a double merge impossible, and a
      # duplicate attempt reads the PR as already merged and settles as a no-op.
      #
      # SO THIS GATE IS NOT THE GUARD, and must not be mistaken for one: two jobs
      # can both pass `pending?` here before either settles. The rule that a
      # settled action is never re-settled lives at the WRITE, where the database
      # can arbitrate it in one statement — ReviewPendingAction#settle!. Do not
      # "fix" a double-settle by widening this lock across the merge; that trades a
      # rare accounting defect for a connection-pool outage.
      claimed = @action.with_lock do
        next false unless @action.pending?

        @action.record_attempt!(now: @now)
        true
      end
      unless claimed
        return already_settled("action is #{@action.state}, not pending — an earlier execution settled it")
      end

      execute
    rescue Github::Client::HttpError => e
      # A GitHub read/write failure is transient by default — stay pending and let
      # the next trigger retry rather than burning an authorised merge on a blip.
      log_error(e)
      result(:error, "GitHub API error: #{e.message.to_s.truncate(200)}")
    rescue StandardError => e
      log_error(e)
      result(:error, "#{e.class}: #{e.message.to_s.truncate(200)}")
    end

    private

    attr_reader :action, :now

    def execute
      # 2. EXPIRY — drop, never execute late. Checked before anything else that
      # could act, so a long-stale order cannot merge on a technicality.
      if action.expired?(now: now)
        return settle(:expired, ReviewPendingAction::EXPIRED,
                      "expired at #{action.expires_at.utc.iso8601} without CI ever settling green")
      end

      task = action.task
      return settle_refused("task #{action.task_slug} no longer exists") unless task

      # 4. NEVER INVENT A VERDICT. The authorising scout report must still be on
      # the record; a decision that has been withdrawn stops authorising anything.
      unless action.verdict_recorded?
        return settle_refused(
          "the authorising #{ReviewPendingAction::AUTHORISING_VERDICT} verdict is no longer on the record"
        )
      end

      # 5. NEVER EXECUTE A REVISED VERDICT. The report that authorised this merge
      # must still be the task's STANDING decision. A reviewer who changed their
      # mind records `request-changes`; they do not disarm the robot, and the
      # autopilot must follow the decision rather than the moment it was armed.
      superseding = action.superseding_scout_report
      if superseding
        return settle_refused(
          "the recorded verdict was revised to " \
          "#{ReviewPendingAction.scout_outcome(superseding).presence || "an unlabelled outcome"} by " \
          "#{superseding.agent_slug.presence || "an agent"} at #{superseding.created_at.utc.iso8601} — " \
          "the standing decision is no longer #{ReviewPendingAction::AUTHORISING_VERDICT}"
        )
      end

      # 6. THE DESTINATION IS THE ACTION TYPE'S, NOT THE ROW'S. Re-read here and not
      # left to the model validation because rows written BEFORE that validation
      # existed are still in the table, and this is the executor's last chance to
      # notice one. An armed merge's blast radius is `accepted` by construction.
      unless action.base_branch_authorised?
        return settle_refused(
          "this action merges to #{action.base_branch.inspect}, but #{action.action} may only merge " \
          "into #{action.required_base_branch}"
        )
      end

      # 7. The order was given at the `submitted` seam. Anywhere else, someone has
      # already acted — merged it, blocked it, or sent it back.
      unless task.stage == AUTHORISED_FROM_STAGE
        return settle_refused("task is #{task.stage}, not #{AUTHORISED_FROM_STAGE} — already acted on")
      end

      # 8. A LIVE reviewer does its own merging. This is the whole premise stated
      # as a guard: the autopilot exists for the reviewer that is GONE. Waiting
      # (not refusing) is deliberate — when the lease lapses, the retry acts.
      claim = TaskReviewClaim.find_by(task_slug: task.slug)
      return result(:waiting, "a live reviewer holds the review claim") if claim&.live?(now: now)

      ci = ci_verdict(task)
      return ci if ci.is_a?(Result)

      pr = pull_request
      gate = gate_pull_request(pr)
      return gate if gate.is_a?(Result)

      merge!(task, pr)
    end

    # 9 + 10. CI must be concluded GREEN — in EVERY repo this task has a PR in — and
    # that green must describe THE PIN. Ci::ReviewGate is DB-native (ingested
    # GithubWorkflowRun rows), so an unwired repo reads :none forever and its actions
    # expire unexecuted — the correct fail-closed outcome, not a silent pass.
    #
    # THE TASK IS THE UNIT FOR GREEN; THE ACTION IS THE UNIT FOR THE PIN. A task that
    # lands PRs in two repos is ONE reviewed change, so a red or still-running second
    # repo must stop this merge even though the merge itself only touches the first —
    # the reviewer's merge-ready verdict covered the whole task, and this component
    # merges with nobody watching. The gate used to read `repositories.first`, so a
    # two-repo task could auto-merge on repo #1's green while repo #2 was red. The
    # head-sha pin below is the opposite question and stays PER REPO: an armed merge
    # names one PR in one repo, and comparing its head against a DIFFERENT repo's
    # green would be the same cross-repo confusion in reverse (a permanent, unearned
    # wait). #verdict carries every repo's own verdict under `repos:`, so the fold and
    # the pin come from ONE read.
    #
    # AND THE PINNED REPO IS ALWAYS IN THAT FOLD (`also:`), which is what keeps the
    # two questions from coming apart. The action's repo need not appear in the task's
    # PR register at all — the arm endpoint takes an explicit `repo`, and a builder
    # who never ran `--pr-url-for` leaves the register short — so without the union
    # the pin read a repo the fold had never voted on. A REPO THAT CAN DECIDE A MERGE
    # MUST BE ABLE TO BLOCK ONE: unioned, a red pinned repo turns the whole verdict
    # red instead of quietly handing over a matching sha.
    #
    # A SECOND REPO'S CI SETTLING RAISES NO WEBHOOK FOR THIS ACTION — the fast path
    # (ReviewPendingAction.trigger_for_head) keys on the pinned repo+sha, which the
    # other repo's run does not match. The arm's self-rescheduling recheck chain
    # (ReviewPendingActionExecutionJob, 2-minute cadence to the TTL) is what carries a
    # multi-repo action to its conclusion, so the wait resolves on its own — and if it
    # never goes green the action expires unexecuted, which is the intended end.
    def ci_verdict(task)
      # `also:` UNIONS the pinned repo into the fold, and that is the whole guard:
      # the repo this action merges INTO gets a vote, so a red or still-running
      # pinned repo turns the task's verdict red instead of quietly supplying a sha.
      verdict = Ci::ReviewGate.verdict(task, also: [pinned_repo])
      state = verdict[:state]
      unless state == :green
        # NAME THE LANE THAT STOPPED US — and, on a multi-repo task, the REPO. "CI is
        # pending" sends whoever reads this back to GitHub to work out WHICH of six
        # lanes; the fold already knows, and this string is the whole account of a
        # merge that did not happen (it is logged now, and recorded on the action if
        # the window later closes). A red outranks a pending, so it is reported first
        # — same precedence as the fold, across repos as well as within one.
        lanes = Array(verdict[:failing]).presence || Array(verdict[:pending]).presence
        return result(:waiting, "CI is #{state}, not green#{blocking_repo_note(verdict)}" \
                                "#{" (absent check-runs are not a pass)" if state == :none}" \
                                "#{" — #{lanes.join(", ")}" if lanes}")
      end

      pinned = pinned_repo_verdict(verdict)
      unless pinned
        return result(:waiting, "the CI verdict does not cover #{pinned_repo.presence || "this action's repo"} — " \
                                "refusing to merge it on another repo's green")
      end

      ci_sha = pinned[:sha].to_s
      if ci_sha.blank? || ci_sha != action.head_sha
        return result(:waiting,
                      "the green CI we hold#{pinned_repo_note} is for " \
                      "#{ci_sha.presence || "an unknown sha"}, not the pinned #{action.head_sha}")
      end

      nil
    end

    # " in turf-monster" when the task spans more than one repo, else "". Silent on a
    # single-repo task, where naming the repo would be noise; load-bearing on a
    # multi-repo one, where "CI is red" alone hides which half of the task is broken.
    def blocking_repo_note(verdict)
      return "" unless verdict[:repos].respond_to?(:size) && verdict[:repos].size > 1
      return "" if verdict[:repo].to_s.strip.empty?

      " in #{verdict[:repo]}"
    end

    # THE PINNED REPO's own verdict, READ OUT OF THE FOLD — never re-read beside it.
    # The action names one PR, so its head_sha can only be compared against THAT
    # repo's runs; because #ci_verdict unions the pinned repo into the fold, the entry
    # is always there and has already been proved green by the time this is called.
    #
    # nil means the fold does not cover the repo this action merges into, which after
    # the union can only be a repo whose name resolves to nothing. It is an assertion,
    # not a fallback: the caller WAITS. The predecessor of this method re-read the
    # pinned repo on a fold miss and used only its `:sha`, so a repo outside the fold
    # contributed a sha and no vote — and a red PR merged into `accepted` unattended.
    # Never answer "is this tree green?" with a verdict nobody folded.
    def pinned_repo_verdict(verdict)
      per_repo = verdict[:repos]
      per_repo.is_a?(Hash) ? per_repo[pinned_repo] : nil
    end

    def pinned_repo
      action.repo_nwo.to_s.split("/").last.to_s
    end

    def pinned_repo_note
      pinned_repo.empty? ? "" : " for #{pinned_repo}"
    end

    def pull_request
      client.get("/repos/#{action.repo_nwo}/pulls/#{action.pr_number}")
    end

    # 11 + 12. The live PR must still be the tree the verdict described, and must
    # still be mergeable.
    def gate_pull_request(pr)
      # Someone (a revived reviewer, a human) already merged it. Not a failure —
      # the order has been carried out, so record it as done and stop retrying.
      if pr["merged"] == true
        return settle(:executed, ReviewPendingAction::EXECUTED,
                      "already merged before this action ran", merge_sha: pr.dig("merge_commit_sha"))
      end

      return settle_refused("PR ##{action.pr_number} is #{pr["state"]}, not open") unless pr["state"] == "open"

      live_head = pr.dig("head", "sha").to_s
      if live_head != action.head_sha
        return settle_refused(
          "head moved from the reviewed #{action.head_sha} to #{live_head} — " \
          "the recorded verdict describes a different tree"
        )
      end

      # The LIVE PR's base must equal the action's, and guard 6 has already fixed
      # the action's to `accepted` — so the two together are what makes "an armed
      # merge lands on accepted" a fact about the code rather than a convention.
      base_ref = pr.dig("base", "ref").to_s
      if base_ref != action.base_branch
        return settle_refused("PR base is #{base_ref}, not the authorised #{action.base_branch}")
      end

      # `mergeable` is nil while GitHub computes the merge commit — a genuine wait.
      # `false` is the CONFLICTING case: the same state that stops CI firing at all,
      # so name it here rather than letting it read as a slow lane.
      return result(:waiting, "GitHub is still computing mergeability") if pr["mergeable"].nil?

      unless pr["mergeable"]
        return settle_refused(
          "PR is not mergeable (#{pr["mergeable_state"].presence || "conflicting"}) — " \
          "resolve the conflict and re-review"
        )
      end

      nil
    end

    # 13. `sha:` is GitHub's own head pin — the API refuses with 409 if the head
    # has moved since our read. It is the server-side twin of the merge SOP's
    # `gh pr merge --match-head-commit`, and it closes the last race: a push that
    # lands between guard 11 and this call.
    def merge!(task, _pr)
      response = client.put_response(
        "/repos/#{action.repo_nwo}/pulls/#{action.pr_number}/merge",
        body: {
          sha:          action.head_sha,
          merge_method: action.merge_method.presence || "merge"
        }
      )

      case response.status
      when 200
        finish_merge(task, response.body["sha"].to_s)
      when 409
        settle_refused("GitHub refused the merge: the head moved off the pinned #{action.head_sha}")
      when 405
        settle_refused("GitHub refused the merge as not mergeable: #{api_message(response)}")
      else
        result(:error, "GitHub merge returned HTTP #{response.status}: #{api_message(response)}")
      end
    end

    # Merge → STAMP → move, the order the review SOP fixes: the task reads
    # `reviewed` if and only if its code is on `accepted`. A stamp/move failure
    # after a successful merge leaves the action settled as executed with the
    # error recorded — the merge is real, and re-running must not re-merge.
    def finish_merge(task, merge_sha)
      task.update!(merged: Task::MERGED_ACCEPTED)
      # ATTRIBUTE THE MACHINE MOVE. This is the one stage transition in the pipeline
      # that no human, CLI, or web form drives, so it was landing on the TaskEvent
      # spine with a blank source and actor — the only anonymous row on the trail,
      # on precisely the transition an audit of this feature asks about first.
      # `autopilot` names the lane; the actor stays the reviewer whose recorded
      # verdict authorised it, because the authority is theirs and only the
      # execution is ours.
      Current.task_event_source = TaskEvent::AUTOPILOT_SOURCE
      Current.task_event_actor  = action.authorized_by.presence
      task.update!(stage: "reviewed")
      settle(:executed, ReviewPendingAction::EXECUTED,
             "merged #{action.head_sha[0, 7]} into #{action.base_branch} on the recorded " \
             "#{action.verdict} verdict by #{action.authorized_by.presence || "a reviewer"}",
             merge_sha: merge_sha)
    rescue StandardError => e
      log_error(e)
      settle(:executed, ReviewPendingAction::EXECUTED,
             "merged #{merge_sha} but the stamp/move failed (#{e.class}: #{e.message.to_s.truncate(120)}) " \
             "— the task needs `bin/task merged … accepted` and `bin/task move … reviewed` by hand",
             merge_sha: merge_sha)
    end

    def api_message(response)
      body = response.body
      (body.is_a?(Hash) ? body["message"] : nil).presence || response.raw_body.to_s.truncate(200)
    end

    def client
      @client ||= Github::Client.new
    end

    # `settle!` is CONDITIONAL — it writes only to a row that is still pending, and
    # tells us whether it did. Losing that race is ordinary (see #already_settled),
    # so the only rule here is that a run which wrote nothing never reports the
    # status of a run that wrote something.
    def settle(status, state, reason, merge_sha: nil)
      return result(status, reason) if action.settle!(state: state, reason: reason, merge_sha: merge_sha, now: now)

      lost_the_settle(state, reason, merge_sha)
    end

    def settle_refused(reason)
      settle(:refused, ReviewPendingAction::REFUSED, reason)
    end

    # A SECOND EXECUTION THAT ARRIVED LATE. It claimed a pending row, did the work,
    # and found the row settled by the time it went to write. Nothing is wrong: two
    # triggers for one armed merge is the normal shape (the CI webhook fires and
    # the arm's own recheck chain is running), and the merge itself was never at
    # risk — GitHub's `sha` pin makes a double merge impossible.
    #
    # IT RECORDS RATHER THAN VANISHES. A silently swallowed double-attempt is its
    # own blindness: `attempts` (bumped under the claim lock, so it never
    # under-counts) says a second job ran, and this reason names what that job
    # would have written beside what actually stands. An operator reading a row
    # that says EXECUTED can see that a sibling was about to call it REFUSED, and
    # why — without that opinion ever having become the record.
    def lost_the_settle(state, discarded_reason, merge_sha)
      # The one thing worth salvaging from the loser: a merge sha the winner did
      # not have. Narrow by construction — see ReviewPendingAction#record_merge_sha!.
      backfilled = action.record_merge_sha!(merge_sha)

      already_settled(
        "already settled #{action.state} by a concurrent execution" \
        "#{" (this attempt supplied the missing merge sha #{action.merge_sha})" if backfilled} — " \
        "this attempt would have written #{state}: #{discarded_reason}"
      )
    end

    # The two paths that must NOT write, reported as one status. `:refused` means
    # "this run SETTLED the action refused"; a run that wrote nothing must never be
    # indistinguishable from one that did, on the very record an incident review
    # reads to find out what the machine decided.
    def already_settled(reason)
      result(:already_settled, reason)
    end

    def result(status, reason)
      @logger&.info("[review-autopilot] #{action.task_slug} #{status}: #{reason}")
      Result.new(status: status, reason: reason, action: action)
    end

    # Backend discipline: every failure path lands in an ErrorLog with the action
    # as its target, so a merge that did not happen is diagnosable in seconds.
    def log_error(error)
      log = ErrorLog.capture!(error)
      log.target = action
      log.target_name = action.task_slug
      log.save!
    rescue StandardError => e
      @logger&.warn("[review-autopilot] ErrorLog capture failed: #{e.class}: #{e.message}")
    end
  end
end
