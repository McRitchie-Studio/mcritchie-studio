# Ingests GitHub Actions webhook deliveries into a GithubWorkflowRun row so the
# board reflects CI + deploy status without polling `gh`. Event families:
#   * `workflow_run`                       — the per-RUN CI/deploy lifecycle
#                                            (queued → in_progress → completed),
#                                            keyed on the immutable run_id.
#   * `workflow_job`                       — the per-JOB CI check lifecycle: one
#                                            CiCheckJob row per Actions job, keyed on
#                                            the immutable job_id, so Ci::ProgressReader
#                                            folds a SHA's checks into a LIVE progress
#                                            bar (v1.1). Only "CI"-workflow jobs are
#                                            recorded — the table exists for that bar.
#
# IDEMPOTENT + MONOTONIC by design. GitHub delivers webhooks AT-LEAST-ONCE and
# OUT OF ORDER, so this job:
#   * keys on the immutable run_id (find_or_initialize) — a re-delivery updates
#     the same row, never a duplicate (the DB unique index is the backstop);
#   * only ever ADVANCES status along GithubWorkflowRun::STATUS_ORDER — a late
#     `in_progress` re-delivery that arrives after `completed` is dropped whole;
#   * records a conclusion once and then only lets a LATER run_attempt correct it,
#     so a re-run's real verdict lands while a re-delivered older/non-terminal
#     event can never wipe it back to nil (see #upsert_run!).
#
# Backend discipline: the body is rescued into ErrorLog and deliberately NOT
# re-raised for non-transient failures — GitHub (or a backfill) will re-deliver,
# and the upsert is idempotent, so we don't want ApplicationJob's retry_on to
# storm on a malformed payload. A genuine INSERT race is the one thing we retry.
class GithubWorkflowRunIngestJob < ApplicationJob
  def perform(event_name, payload)
    payload = stringify(payload)
    @run_id = nil
    @job_id = nil

    case event_name.to_s
    when "workflow_run"
      ingest_workflow_run(payload)
    when "workflow_job"
      ingest_workflow_job(payload)
    else
      Rails.logger.info("[GithubWorkflowRunIngestJob] ignoring event=#{event_name.inspect}")
    end
  rescue StandardError => e
    log = ErrorLog.capture!(e)
    log.target_name = (@run_id || @job_id).to_s if (@run_id || @job_id).present?
    log.save!
  end

  private

  # ── workflow_run lifecycle ────────────────────────────────────────────────
  def ingest_workflow_run(payload)
    run = payload["workflow_run"] || {}
    @run_id = run["id"]
    if @run_id.blank?
      Rails.logger.warn("[GithubWorkflowRunIngestJob] workflow_run.id missing; skipping")
      return
    end

    upsert_run!(run_id: @run_id, run: run, repo: payload.dig("repository", "full_name"))
  end

  def upsert_run!(run_id:, run:, repo:)
    with_insert_retry do
      record = GithubWorkflowRun.find_or_initialize_by(run_id: run_id)
      incoming = run["status"].to_s
      # nil when the payload omits it (older deliveries) — treated as attempt 1,
      # which is what an un-re-run workflow is.
      incoming_attempt = run["run_attempt"].presence&.to_i

      # MONOTONIC guard: drop a status that ranks BELOW what we already stored
      # (a late / out-of-order re-delivery) without touching the row.
      return if record.persisted? && GithubWorkflowRun.status_rank(incoming) < GithubWorkflowRun.status_rank(record.status)

      # MONOTONIC guard, attempt edition — same shape, same reason. An older
      # attempt's delivery is dropped WHOLE rather than partially applied. Applying
      # it in part is what made the first cut of this fix wrong: a non-terminal
      # attempt-2 delivery advanced run_attempt while the conclusion was still
      # blank, a late attempt-1 `completed` then filled that blank, and attempt 2's
      # real verdict was refused as "not newer" — landing a stale GREEN on a run
      # that failed, or pinning the row RED after a re-run went green.
      return if record.persisted? && incoming_attempt && incoming_attempt < record.run_attempt.to_i

      apply_descriptive_fields(record, run, repo)
      record.status = incoming if incoming.present?

      # CONCLUSION: fill a blank, or let a NEWER ATTEMPT's terminal verdict correct
      # a recorded one. GitHub re-runs a failed run under the SAME run_id (bumping
      # run_attempt), so the old blanket first-write-wins pinned the row at
      # `failure` for good — and Ci::ReviewGate reads these rows and nothing else,
      # so `bin/task claim-next-review` could never pop a PR whose flake a re-run
      # had already fixed: green on GitHub, unclaimable on the board, permanently.
      #
      # Gated on the ATTEMPT, not merely on `completed`, because deliveries arrive
      # out of order: a late replay of attempt 1's `completed` must never overwrite
      # attempt 2's verdict. That direction matters — this row AUTHORISES A MERGE,
      # so a stale attempt landing a green over a real red is the unsafe case. A
      # non-terminal delivery still can't wipe a conclusion back to nil.
      if run["conclusion"].present? && (record.conclusion.blank? || newer_attempt?(record, incoming_attempt))
        record.conclusion = run["conclusion"]
      end
      record.run_attempt = incoming_attempt if incoming_attempt && incoming_attempt >= record.run_attempt.to_i

      record.save!

      # THE AUTOPILOT TRIGGER. A settled run is the moment an armed merge becomes
      # executable, and this row is the board's only news of it — Ci::ReviewGate
      # reads these rows and nothing else. Fire only on a CONCLUSION: a queued or
      # in_progress delivery can never make a merge eligible, and re-checking on
      # it would just burn a job.
      #
      # Best-effort by design: the autopilot is a convenience over an already
      # durable record, so a trigger failure must never break CI ingestion. A
      # missed trigger is picked up by the action's own recheck chain
      # (ReviewPendingActionExecutionJob) within minutes.
      trigger_review_autopilot(record) if record.conclusion.present?
    end
  end

  def trigger_review_autopilot(record)
    ReviewPendingAction.trigger_for_head(repo: record.repo, head_sha: record.head_sha)
  rescue StandardError => e
    Rails.logger.warn("[GithubWorkflowRunIngestJob] autopilot trigger failed for run #{record.run_id}: " \
                      "#{e.class}: #{e.message}")
    nil
  end

  # Does this delivery describe a LATER run attempt than the one whose conclusion
  # we already stored? Consulted ONLY when a conclusion is recorded (the caller
  # fills a blank outright). A missing run_attempt — an older payload, or a row
  # ingested before the column existed — reads as 0, so the first re-run (attempt
  # 2) correctly supersedes a legacy row, an at-least-once re-delivery of the same
  # attempt is a no-op, and a late replay of an EARLIER attempt is refused.
  def newer_attempt?(record, incoming_attempt)
    incoming_attempt.to_i > record.run_attempt.to_i
  end

  # ── workflow_job lifecycle (per-check LIVE progress) ──────────────────────
  # One CiCheckJob row per Actions job, upserted on every queued/in_progress/
  # completed delivery, so Ci::ProgressReader folds a SHA's checks into a live
  # bar. Only "CI"-workflow jobs are recorded — the deploy workflows' jobs never
  # feed a CI bar, and the table is purpose-built for it. Head_sha is required
  # (the fold is SHA-keyed); a job event missing it or the id is skipped.
  def ingest_workflow_job(payload)
    job = payload["workflow_job"] || {}
    @job_id = job["id"]
    if @job_id.blank?
      Rails.logger.warn("[GithubWorkflowRunIngestJob] workflow_job.id missing; skipping")
      return
    end
    # Record per-job progress for every CI-SUITE workflow we surface — the app
    # repos' `CI` and each gem's own suite (e.g. studio-engine's "Engine CI") — so a
    # gem's release track has LIVE, per-workflow rows (and live-updates on ingest)
    # instead of falling through to the workflow-blind check-runs API, which blends
    # sibling workflows on the same SHA.
    return unless GithubWorkflowRun::CI_PROGRESS_WORKFLOWS.include?(job["workflow_name"].to_s)

    head_sha = job["head_sha"].to_s.presence
    if head_sha.blank?
      Rails.logger.warn("[GithubWorkflowRunIngestJob] workflow_job ##{@job_id} missing head_sha; skipping")
      return
    end

    upsert_job!(job: job, repo: payload.dig("repository", "full_name"), head_sha: head_sha)
  end

  def upsert_job!(job:, repo:, head_sha:)
    with_insert_retry do
      record = CiCheckJob.find_or_initialize_by(job_id: @job_id)
      incoming = job["status"].to_s

      # MONOTONIC guard: drop a status ranking BELOW what we already stored (a late
      # / out-of-order re-delivery) without touching the row — mirrors the run upsert.
      return if record.persisted? && CiCheckJob.status_rank(incoming) < CiCheckJob.status_rank(record.status)

      record.repo          = repo if repo.present?
      record.run_id      ||= job["run_id"]
      record.head_sha    ||= head_sha
      record.head_branch ||= job["head_branch"].presence
      record.workflow_name = job["workflow_name"] if job["workflow_name"].present?
      record.name          = job["name"] if job["name"].present?
      record.started_at  ||= parse_time(job["started_at"])
      record.status        = incoming if incoming.present?

      # FIRST-WRITE-WINS on conclusion + completed_at — never overwrite a settled result.
      record.conclusion   = job["conclusion"] if job["conclusion"].present? && record.conclusion.blank?
      record.completed_at ||= parse_time(job["completed_at"])

      record.save!
    end
  end

  # ── shared helpers ────────────────────────────────────────────────────────

  # Fill the descriptive columns from a workflow_run object. head_sha/branch/
  # run_started_at are FIRST-WRITE-WINS (a re-delivery must not clobber what the
  # first event set), while repo/name/url refresh when present (same value, harmless).
  def apply_descriptive_fields(record, run, repo)
    record.repo           = repo           if repo.present?
    record.workflow_name  = run["name"]    if run["name"].present?
    record.html_url       = run["html_url"] if run["html_url"].present?
    record.head_sha       ||= run["head_sha"].presence
    record.head_branch    ||= run["head_branch"].presence
    record.run_started_at ||= parse_time(run["run_started_at"])
  end

  # A concurrent first-delivery can win the INSERT. Re-run once: find_or_initialize
  # now finds that row and applies this event on top of it, monotonically.
  def with_insert_retry
    attempts = 0
    begin
      yield
    rescue ActiveRecord::RecordNotUnique
      attempts += 1
      raise if attempts > 1
      retry
    end
  end

  def parse_time(value)
    return nil if value.blank?

    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  # Production hands us a JSON.parse'd hash (string keys); tests may pass symbol
  # keys or an indifferent hash. Normalize so dig/[] are consistent.
  def stringify(payload)
    payload = payload.to_unsafe_h if payload.respond_to?(:to_unsafe_h)
    payload.respond_to?(:deep_stringify_keys) ? payload.deep_stringify_keys : payload
  end
end
