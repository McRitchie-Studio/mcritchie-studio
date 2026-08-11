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
  #   1. still pending            — a settled action never runs twice
  #   2. not expired              — a stale order is DROPPED, never executed late
  #   3. task still exists        — nothing to merge into otherwise
  #   4. verdict still recorded   — a withdrawn decision stops authorising
  #   5. task still `submitted`   — someone else already moved it
  #   6. no LIVE reviewer         — if a reviewer is awake, it does its own merge
  #   7. CI concluded GREEN       — red / pending / cancelled / ABSENT all do nothing
  #   8. that green is FOR THE PIN— the CI we hold must describe the reviewed tree
  #   9. live PR head == the pin  — the tree must still BE the reviewed tree
  #  10. PR open and mergeable    — a CONFLICTING PR is refused, not merged
  #  11. GitHub re-checks the pin — `sha:` on the merge API; 409 if it moved
  #
  # Guards 7 and 8 are why "no checks reported" cannot slip through. A CONFLICTING
  # PR stops GitHub Actions firing ENTIRELY rather than going red, so its checks
  # read as absent; Ci::ReviewGate folds absent check-runs to :none, and :none is
  # not :green. Guard 10 then names the real cause instead of letting it look like
  # a slow lane.
  #
  # Guards 8, 9 and 11 are three independent readings of ONE rule — the verdict
  # described a specific tree. They can disagree (CI can lag a push; a push can
  # land between our read and our write), and the disagreement is the point: any
  # one of them dissenting stops the merge.
  class PendingActionExecutor
    # :executed — merged, stamped, and moved to `reviewed`
    # :waiting  — nothing is wrong yet; conditions are not met. Stays pending.
    # :refused  — this action can never be right. Settled, terminal.
    # :expired  — its window closed. Settled, terminal.
    # :error    — an unexpected failure. Stays pending so a retry can succeed.
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
      # GitHub's own `sha` pin (guard 11) makes a double merge impossible, and a
      # duplicate attempt reads the PR as already merged and settles as a no-op.
      claimed = @action.with_lock do
        next false unless @action.pending?

        @action.record_attempt!(now: @now)
        true
      end
      return refuse_without_settling("action is #{@action.state}, not pending") unless claimed

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

      # 5. The order was given at the `submitted` seam. Anywhere else, someone has
      # already acted — merged it, blocked it, or sent it back.
      unless task.stage == AUTHORISED_FROM_STAGE
        return settle_refused("task is #{task.stage}, not #{AUTHORISED_FROM_STAGE} — already acted on")
      end

      # 6. A LIVE reviewer does its own merging. This is the whole premise stated
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

    # 7 + 8. CI must be concluded GREEN, and that green must describe THE PIN.
    # Ci::ReviewGate is DB-native (ingested GithubWorkflowRun rows), so an unwired
    # repo reads :none forever and its actions expire unexecuted — the correct
    # fail-closed outcome, not a silent pass.
    def ci_verdict(task)
      verdict = Ci::ReviewGate.verdict(task)
      state = verdict[:state]
      unless state == :green
        return result(:waiting, "CI is #{state}, not green" \
                                "#{" (absent check-runs are not a pass)" if state == :none}")
      end

      ci_sha = verdict[:sha].to_s
      if ci_sha.blank? || ci_sha != action.head_sha
        return result(:waiting,
                      "the green CI we hold is for #{ci_sha.presence || "an unknown sha"}, " \
                      "not the pinned #{action.head_sha}")
      end

      nil
    end

    def pull_request
      client.get("/repos/#{action.repo_nwo}/pulls/#{action.pr_number}")
    end

    # 9 + 10. The live PR must still be the tree the verdict described, and must
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

    # 11. `sha:` is GitHub's own head pin — the API refuses with 409 if the head
    # has moved since our read. It is the server-side twin of the merge SOP's
    # `gh pr merge --match-head-commit`, and it closes the last race: a push that
    # lands between guard 9 and this call.
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

    def settle(status, state, reason, merge_sha: nil)
      action.settle!(state: state, reason: reason, merge_sha: merge_sha, now: now)
      result(status, reason)
    end

    def settle_refused(reason)
      settle(:refused, ReviewPendingAction::REFUSED, reason)
    end

    # The one refusal that must NOT write: the action is already settled, so
    # re-stamping it would overwrite the real outcome with this bookkeeping one.
    def refuse_without_settling(reason)
      result(:refused, reason)
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
