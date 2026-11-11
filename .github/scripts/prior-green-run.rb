# frozen_string_literal: true

# TEST EACH SHA ONCE (task release-sub-hour-pipeline). reusable-ci.yml's `prior_green`
# job runs this before any lane. It answers one question for a push to `main` or
# `release`: did a completed run of THIS SAME WORKFLOW already conclude `success` on
# THIS SAME COMMIT? A fast-forwarded `release` is the `accepted` head CI already ran,
# and a ship fast-forwards `main` to the `release` SHA; each push queued the whole suite
# again on content it had already passed. When the answer is yes, every lane skips and
# the run reads green in seconds, while the earlier run's checks stay on the SHA.
#
# It credits ONLY a run where every one of these holds (anything less runs the suite):
#
#   * this run is a `push` to refs/heads/main or refs/heads/release (a PR, an
#     `accepted` push and any other event always run the suite);
#   * the earlier run is a DIFFERENT run (`id` is not this run's id);
#   * it ran the SAME workflow file (`path`, read from GITHUB_WORKFLOW_REF);
#   * its `head_sha` is exactly this commit, in this repository;
#   * it was a `push` run (a `pull_request` run checks out a MERGE ref, not this commit);
#   * it is `completed` with conclusion `success`.
#
# A skip-run itself concludes `success`, so a later push of the same SHA can credit it;
# every such chain ends at a run that executed every lane on this exact commit.
#
# Usage: ruby prior-green-run.rb RUNS_JSON — RUNS_JSON is the body of
# `gh api repos/<repo>/actions/runs?head_sha=<sha>`; the rest comes from the Actions
# environment. It prints `skip=true|false` and `reason=…` for $GITHUB_OUTPUT and ALWAYS
# exits 0: an unreadable body or any fault prints skip=false, so the suite runs.
require "json"

module PriorGreenRun
  BRANCHES = %w[refs/heads/main refs/heads/release].freeze

  module_function

  # The workflow file path from GITHUB_WORKFLOW_REF
  # ("owner/repo/.github/workflows/ci.yml@refs/heads/main" → ".github/workflows/ci.yml").
  def workflow_path(workflow_ref)
    match = workflow_ref.to_s.match(%r{\A[^/]+/[^/]+/(?<path>[^@]+)@})
    match ? match[:path] : ""
  end

  # PURE. env (a Hash of the GITHUB_* values) + the runs body → [skip, reason].
  def decide(env, runs_body)
    event = env["GITHUB_EVENT_NAME"].to_s
    ref = env["GITHUB_REF"].to_s
    return [false, "a #{event.empty? ? 'unknown' : event} event on #{ref} always runs the suite"] unless event == "push" && BRANCHES.include?(ref)

    sha = env["GITHUB_SHA"].to_s.downcase
    run_id = env["GITHUB_RUN_ID"].to_s
    repo = env["GITHUB_REPOSITORY"].to_s
    path = workflow_path(env["GITHUB_WORKFLOW_REF"])
    return [false, "the commit, run, repository or workflow path is unknown"] if [sha, run_id, repo, path].any?(&:empty?)

    data = JSON.parse(runs_body.to_s)
    runs = data.is_a?(Hash) ? data["workflow_runs"] : nil
    return [false, "the workflow runs for #{sha[0, 7]} could not be read"] unless runs.is_a?(Array)

    prior = runs.find { |run| credits?(run, sha: sha, run_id: run_id, repo: repo, path: path) }
    return [false, "no earlier push run of #{path} concluded success on #{sha[0, 7]}"] unless prior

    [true, "run #{prior['id']} (#{prior['head_branch']}) already concluded success on #{sha[0, 7]}"]
  rescue StandardError => e
    [false, "the check failed (#{e.class}) — running the suite"]
  end

  def credits?(run, sha:, run_id:, repo:, path:)
    return false unless run.is_a?(Hash)

    run["id"].to_s != run_id &&
      run["path"].to_s == path &&
      run["head_sha"].to_s.downcase == sha &&
      run.dig("repository", "full_name").to_s == repo &&
      run["event"] == "push" &&
      run["status"] == "completed" &&
      run["conclusion"] == "success"
  end

  def output(skip, reason)
    "skip=#{skip}\nreason=#{reason.to_s.tr("\n", ' ')}\n"
  end
end

if $PROGRAM_NAME == __FILE__
  body = begin
    File.read(ARGV.fetch(0))
  rescue StandardError
    ""
  end
  skip, reason = PriorGreenRun.decide(ENV.to_h, body)
  $stdout.write(PriorGreenRun.output(skip, reason))
  exit 0
end
