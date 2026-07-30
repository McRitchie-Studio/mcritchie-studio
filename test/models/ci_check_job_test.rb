require "test_helper"

# [unit] CiCheckJob — one GitHub Actions workflow_job per row, the per-check
# source Ci::ProgressReader folds into a LIVE progress bar. Pins the invariants
# the ingest + reader depend on: the required keys, the unique job_id, the
# monotonic status rank, and the { status, conclusion } fold rows.
class CiCheckJobTest < ActiveSupport::TestCase
  def build_job(**overrides)
    CiCheckJob.new({
      repo: "McRitchie-Studio/mcritchie-studio", job_id: 1, head_sha: "abc123",
      head_branch: "feat/x", workflow_name: "CI", name: "lint", status: "completed",
      conclusion: "success"
    }.merge(overrides))
  end

  test "[unit] requires repo, job_id, head_sha, and status" do
    assert build_job.valid?
    %i[repo job_id head_sha status].each do |attr|
      job = build_job(attr => nil)
      assert_not job.valid?, "#{attr} should be required"
      assert_includes job.errors.attribute_names, attr
    end
  end

  test "[unit] job_id is unique — a re-delivery can only update, never duplicate" do
    build_job(job_id: 42).save!
    dup = build_job(job_id: 42, head_sha: "other")
    assert_not dup.valid?
    assert_includes dup.errors.attribute_names, :job_id
  end

  test "[unit] the unique job_id index blocks a duplicate insert" do
    build_job(job_id: 7).save!
    assert_raises(ActiveRecord::RecordNotUnique) do
      build_job(job_id: 7, head_sha: "z").save!(validate: false)
    end
  end

  test "[unit] status_rank orders the lifecycle and floors the unknown at -1" do
    assert_equal 0, CiCheckJob.status_rank("queued")
    assert_equal 1, CiCheckJob.status_rank("in_progress")
    assert_equal 2, CiCheckJob.status_rank("completed")
    assert_equal(-1, CiCheckJob.status_rank("garbage"), "an unknown status must never outrank a real one")
  end

  test "[unit] progress_rows returns the { status, conclusion, name } fold rows for a repo+SHA" do
    build_job(job_id: 1, head_sha: "s1", name: "lint", status: "completed", conclusion: "success").save!
    build_job(job_id: 2, head_sha: "s1", name: "test", status: "in_progress", conclusion: nil).save!
    build_job(job_id: 3, head_sha: "OTHER", name: "lint", status: "completed", conclusion: "failure").save!

    rows = CiCheckJob.progress_rows("McRitchie-Studio/mcritchie-studio", "s1")
    assert_equal 2, rows.size, "only the two jobs for this repo+SHA"
    assert_includes rows, { "status" => "completed", "conclusion" => "success", "name" => "lint" }
    assert_includes rows, { "status" => "in_progress", "conclusion" => nil, "name" => "test" }
    # The rows fold straight into a Ci::CheckProgress — 1 passed of 2.
    progress = Ci::CheckProgress.from_check_runs(rows, sha: "s1")
    assert_equal "1 / 2", progress.fraction_label
  end

  test "[unit] progress_rows is empty when no job has landed (reader then falls back)" do
    assert_empty CiCheckJob.progress_rows("McRitchie-Studio/mcritchie-studio", "never-seen")
  end

  # ── the reset/re-run duplication fix (v1.2): a re-run mints new job_ids for the
  #    same check names on the same SHA; progress_rows must fold ONLY the latest
  #    attempt of each check, so the count RESETS fresh instead of doubling. ──────

  test "[unit] a re-run does not duplicate — only the latest attempt per check folds" do
    # Attempt 1: three checks under run 100 (lint fails, test/build pass).
    build_job(job_id: 1, run_id: 100, head_sha: "sha", name: "lint",  status: "completed", conclusion: "failure").save!
    build_job(job_id: 2, run_id: 100, head_sha: "sha", name: "test",  status: "completed", conclusion: "success").save!
    build_job(job_id: 3, run_id: 100, head_sha: "sha", name: "build", status: "completed", conclusion: "success").save!
    # Re-run (a new workflow_run, 101) mints NEW job_ids for the SAME names.
    build_job(job_id: 4, run_id: 101, head_sha: "sha", name: "lint",  status: "in_progress", conclusion: nil).save!
    build_job(job_id: 5, run_id: 101, head_sha: "sha", name: "test",  status: "in_progress", conclusion: nil).save!
    build_job(job_id: 6, run_id: 101, head_sha: "sha", name: "build", status: "in_progress", conclusion: nil).save!

    rows = CiCheckJob.progress_rows("McRitchie-Studio/mcritchie-studio", "sha")

    assert_equal 3, rows.size, "the re-run RESETS to 3 checks, never accumulates to 6"
    assert_equal %w[in_progress in_progress in_progress].sort, rows.map { |r| r["status"] }.sort,
      "the count reflects the LATEST attempt (fresh/pending), not the settled old one"
    assert_equal "0 / 3", Ci::CheckProgress.from_check_runs(rows).fraction_label
  end

  test "[unit] re-run of a single FAILED job (same run, higher job_id) keeps the newer row" do
    # Same run_id (a 're-run failed jobs'): only lint is re-run, with a higher job_id.
    build_job(job_id: 10, run_id: 200, head_sha: "sha", name: "lint", status: "completed", conclusion: "failure").save!
    build_job(job_id: 11, run_id: 200, head_sha: "sha", name: "test", status: "completed", conclusion: "success").save!
    build_job(job_id: 12, run_id: 200, head_sha: "sha", name: "lint", status: "completed", conclusion: "success").save!

    rows = CiCheckJob.progress_rows("McRitchie-Studio/mcritchie-studio", "sha")
    assert_equal 2, rows.size, "two distinct checks — lint's retry replaces its first row"
    lint = rows.find { |r| r["name"] == "lint" }
    assert_equal "success", lint["conclusion"], "the newer (higher job_id) lint attempt wins"
    assert_equal "2 / 2", Ci::CheckProgress.from_check_runs(rows).fraction_label
  end

  test "[unit] blank-named rows are never collapsed — each keys on its own job_id" do
    build_job(job_id: 20, head_sha: "sha", name: nil, status: "completed", conclusion: "success").save!
    build_job(job_id: 21, head_sha: "sha", name: nil, status: "completed", conclusion: "success").save!

    rows = CiCheckJob.progress_rows("McRitchie-Studio/mcritchie-studio", "sha")
    assert_equal 2, rows.size, "two nameless checks stay distinct, not folded into one"
  end

  test "[unit] terminal? is true only once completed" do
    assert build_job(status: "completed").terminal?
    assert_not build_job(status: "in_progress").terminal?
  end
end
