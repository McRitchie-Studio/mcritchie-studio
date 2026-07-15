# Ingests a GitHub Actions `workflow_run` webhook delivery into a
# GithubWorkflowRun row so the board reflects CI status without polling `gh`.
#
# IDEMPOTENT + MONOTONIC by design. GitHub delivers webhooks AT-LEAST-ONCE and
# OUT OF ORDER, so this job:
#   * keys on the immutable run_id (find_or_initialize) — a re-delivery updates
#     the same row, never a duplicate (the DB unique index is the backstop);
#   * only ever ADVANCES status along GithubWorkflowRun::STATUS_ORDER — a late
#     `in_progress` re-delivery that arrives after `completed` is dropped whole;
#   * treats a completed run's conclusion as FIRST-WRITE-WINS, so a re-delivered
#     non-terminal event can never wipe it back to nil.
#
# Backend discipline: the body is rescued into ErrorLog and deliberately NOT
# re-raised for non-transient failures — GitHub (or a backfill) will re-deliver,
# and the upsert is idempotent, so we don't want ApplicationJob's retry_on to
# storm on a malformed payload. A genuine INSERT race is the one thing we retry.
class GithubWorkflowRunIngestJob < ApplicationJob
  def perform(event_name, payload)
    unless event_name.to_s == "workflow_run"
      Rails.logger.info("[GithubWorkflowRunIngestJob] ignoring event=#{event_name.inspect}")
      return
    end

    payload = stringify(payload)
    run = payload["workflow_run"] || {}
    run_id = run["id"]
    if run_id.blank?
      Rails.logger.warn("[GithubWorkflowRunIngestJob] workflow_run.id missing; skipping")
      return
    end

    upsert!(run_id: run_id, run: run, repo: payload.dig("repository", "full_name"))
  rescue StandardError => e
    log = ErrorLog.capture!(e)
    log.target_name = run_id.to_s if defined?(run_id) && run_id.present?
    log.save!
  end

  private

  def upsert!(run_id:, run:, repo:)
    attempts = 0
    begin
      record = GithubWorkflowRun.find_or_initialize_by(run_id: run_id)
      incoming = run["status"].to_s

      # MONOTONIC guard: drop a status that ranks BELOW what we already stored
      # (a late / out-of-order re-delivery) without touching the row.
      return if record.persisted? && GithubWorkflowRun.status_rank(incoming) < GithubWorkflowRun.status_rank(record.status)

      record.repo           = repo                  if repo.present?
      record.workflow_name  = run["name"]           if run["name"].present?
      record.head_sha       = run["head_sha"]       if run["head_sha"].present?
      record.head_branch    = run["head_branch"]    if run["head_branch"].present?
      record.html_url       = run["html_url"]       if run["html_url"].present?
      record.run_started_at = run["run_started_at"] if run["run_started_at"].present?
      record.status         = incoming              if incoming.present?

      # FIRST-WRITE-WINS on conclusion — never overwrite a recorded conclusion.
      record.conclusion = run["conclusion"] if run["conclusion"].present? && record.conclusion.blank?

      record.save!
    rescue ActiveRecord::RecordNotUnique
      # A concurrent first-delivery won the INSERT. Re-run once: find_or_initialize
      # now finds that row and applies this event monotonically on top of it.
      attempts += 1
      raise if attempts > 1
      retry
    end
  end

  # Production hands us a JSON.parse'd hash (string keys); tests may pass symbol
  # keys or an indifferent hash. Normalize so dig/[] are consistent.
  def stringify(payload)
    payload = payload.to_unsafe_h if payload.respond_to?(:to_unsafe_h)
    payload.respond_to?(:deep_stringify_keys) ? payload.deep_stringify_keys : payload
  end
end
