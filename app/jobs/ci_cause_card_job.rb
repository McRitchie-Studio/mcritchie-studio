require Rails.root.join("bin/lib/ci_cause_detector").to_s

# Files the cause cards for one red CI attempt that a later run at the same SHA proved
# green (Ci::CauseCard; the ruling and the classes are in bin/lib/ci_cause_detector.rb).
#
# ENQUEUED BY GithubWorkflowRunIngestJob the moment the green lands (a re-run that
# passed, or a second run at the same SHA), and by `bin/rails ci:causes:sweep` over
# CI history. It reads the red attempt's failed jobs and their logs from GitHub, hands
# each log to CiCauseDetector.causes, and files or folds one card per cause.
#
# Best-effort: a cause card is a record ABOUT CI, so a GitHub read that fails costs
# this one red its card (an ErrorLog row says so) and never touches the ingest. It is
# idempotent: an occurrence is keyed on run, attempt and job, so a re-delivered
# webhook or a second sweep folds nothing twice.
class CiCauseCardJob < ApplicationJob
  MAX_JOBS = 8
  RED = CiCauseDetector::RED

  def perform(repo, run_id, attempt, green_run_id = nil, green_attempt = nil, client: Github::Client.new)
    jobs = client.get("/repos/#{repo}/actions/runs/#{run_id}/attempts/#{attempt}/jobs", params: { per_page: 100 })
    failed = Array(jobs["jobs"]).select { |j| RED.include?(j["conclusion"].to_s) }
    failed.sort_by { |j| j["name"].to_s.match?(CiCauseDetector::ECHO_JOB) ? 1 : 0 }.first(MAX_JOBS).each do |job|
      log = client.get_text("/repos/#{repo}/actions/jobs/#{job['id']}/logs")
      CiCauseDetector.causes(job_name: job["name"], log: log).each do |cause|
        Ci::CauseCard.file!(repo: repo, cause: cause, occurrence: occurrence(repo, run_id, attempt, job, green_run_id, green_attempt))
      end
    end
  rescue StandardError => e
    log = ErrorLog.capture!(e)
    log.target_name = "ci-cause #{repo}##{run_id}/#{attempt}"
    log.save!
  end

  private

  def occurrence(repo, run_id, attempt, job, green_run_id, green_attempt)
    {
      "id" => "#{run_id}/#{attempt}/#{job['id']}",
      "run_url" => "https://github.com/#{repo}/actions/runs/#{run_id}/attempts/#{attempt}",
      "job" => job["name"].to_s,
      "job_url" => job["html_url"].to_s,
      "sha" => job["head_sha"].to_s,
      "green_run_url" => green_run_id && "https://github.com/#{repo}/actions/runs/#{green_run_id}/attempts/#{green_attempt || 1}"
    }.compact
  end
end
