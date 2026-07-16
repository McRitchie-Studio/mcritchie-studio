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
#   * `deployment_review` /                — a run reached a protected environment
#     `deployment_protection_rule`           (required reviewers) and is WAITING on
#                                            a human. Stamps `pending_environment`
#                                            so /deployments shows an Approve row.
#
# IDEMPOTENT + MONOTONIC by design. GitHub delivers webhooks AT-LEAST-ONCE and
# OUT OF ORDER, so this job:
#   * keys on the immutable run_id (find_or_initialize) — a re-delivery updates
#     the same row, never a duplicate (the DB unique index is the backstop);
#   * only ever ADVANCES status along GithubWorkflowRun::STATUS_ORDER — a late
#     `in_progress` re-delivery that arrives after `completed` is dropped whole;
#   * treats a completed run's conclusion as FIRST-WRITE-WINS, so a re-delivered
#     non-terminal event can never wipe it back to nil;
#   * the pending-approval flag is ORTHOGONAL to the status ladder: a review event
#     sets it, a resolve/complete clears it, and neither is subject to the
#     monotonic status guard.
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
    when *GithubWorkflowRun::PENDING_REVIEW_EVENTS
      ingest_deployment_review(payload)
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

      # MONOTONIC guard: drop a status that ranks BELOW what we already stored
      # (a late / out-of-order re-delivery) without touching the row.
      return if record.persisted? && GithubWorkflowRun.status_rank(incoming) < GithubWorkflowRun.status_rank(record.status)

      apply_descriptive_fields(record, run, repo)
      record.status = incoming if incoming.present?

      # FIRST-WRITE-WINS on conclusion — never overwrite a recorded conclusion.
      record.conclusion = run["conclusion"] if run["conclusion"].present? && record.conclusion.blank?

      # A completed run is no longer waiting on anyone — clear a stale pending flag.
      if incoming == "completed"
        record.pending_environment = nil
        record.pending_since = nil
      end

      record.save!
    end
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
    return unless job["workflow_name"].to_s == GithubWorkflowRun::CI_WORKFLOW

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

  # ── deployment review (pending-approval gate) ─────────────────────────────
  # `requested` → the run is now waiting on a reviewer; stamp the environment and
  # nudge Discord on the transition INTO pending. `approved` / `rejected` → the
  # review resolved; clear the flag. Everything is keyed on the same run_id, so a
  # review event finds (or seeds) the very row workflow_run events maintain.
  def ingest_deployment_review(payload)
    run = payload["workflow_run"] || {}
    @run_id = run["id"].presence || payload["workflow_run_id"]
    if @run_id.blank?
      Rails.logger.warn("[GithubWorkflowRunIngestJob] deployment review missing workflow_run id; skipping")
      return
    end

    requested = payload["action"].to_s == "requested"
    environment = payload["environment"].to_s.presence

    entered_pending = with_insert_retry do
      record = GithubWorkflowRun.find_or_initialize_by(run_id: @run_id)
      was_pending = record.pending_approval?

      apply_descriptive_fields(record, run, payload.dig("repository", "full_name"))
      # A waiting deploy is mid-flight; give a freshly-seeded row a NOT-NULL status
      # floor without disturbing a status a workflow_run event already advanced.
      record.status = "in_progress" if record.status.blank?

      if requested && environment
        record.pending_environment = environment
        record.pending_since ||= parse_time(payload["since"]) || Time.current
      else
        record.pending_environment = nil
        record.pending_since = nil
      end

      record.save!
      requested && environment && !was_pending
    end

    notify_pending(@run_id) if entered_pending
  end

  # ── shared helpers ────────────────────────────────────────────────────────

  # Fill the descriptive columns from a workflow_run object. head_sha/branch/url
  # are FIRST-WRITE-WINS (a review event must not clobber what workflow_run set),
  # while repo/name refresh when present (same value, harmless).
  def apply_descriptive_fields(record, run, repo)
    record.repo           = repo           if repo.present?
    record.workflow_name  = run["name"]    if run["name"].present?
    record.html_url       = run["html_url"] if run["html_url"].present?
    record.head_sha       ||= run["head_sha"].presence
    record.head_branch    ||= run["head_branch"].presence
    record.run_started_at ||= parse_time(run["run_started_at"])
  end

  # Nudge qa-chatter that a prod deploy is waiting on approval. Isolated so a
  # Discord/transport failure logs to ErrorLog and NEVER aborts the upsert that
  # already committed (backend rescue discipline — never raise out of here).
  def notify_pending(run_id)
    run = GithubWorkflowRun.find_by(run_id: run_id)
    Devops::DeployApprovalNotifier.notify_pending(run) if run&.pending_approval?
  rescue StandardError => e
    ErrorLog.capture!(e)
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
