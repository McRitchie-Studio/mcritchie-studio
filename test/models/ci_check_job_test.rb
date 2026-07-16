require "test_helper"

# [unit] CiCheckJob — one GitHub Actions workflow_job per row, the per-check
# source Ci::ProgressReader folds into a LIVE progress bar. Pins the invariants
# the ingest + reader depend on: the required keys, the unique job_id, the
# monotonic status rank, and the { status, conclusion } fold rows.
class CiCheckJobTest < ActiveSupport::TestCase
  def build_job(**overrides)
    CiCheckJob.new({
      repo: "amcritchie/mcritchie-studio", job_id: 1, head_sha: "abc123",
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

  test "[unit] progress_rows returns the { status, conclusion } fold rows for a repo+SHA" do
    build_job(job_id: 1, head_sha: "s1", status: "completed", conclusion: "success").save!
    build_job(job_id: 2, head_sha: "s1", status: "in_progress", conclusion: nil).save!
    build_job(job_id: 3, head_sha: "OTHER", status: "completed", conclusion: "failure").save!

    rows = CiCheckJob.progress_rows("amcritchie/mcritchie-studio", "s1")
    assert_equal 2, rows.size, "only the two jobs for this repo+SHA"
    assert_includes rows, { "status" => "completed", "conclusion" => "success" }
    assert_includes rows, { "status" => "in_progress", "conclusion" => nil }
    # The rows fold straight into a Ci::CheckProgress — 1 passed of 2.
    progress = Ci::CheckProgress.from_check_runs(rows, sha: "s1")
    assert_equal "1 / 2", progress.fraction_label
  end

  test "[unit] progress_rows is empty when no job has landed (reader then falls back)" do
    assert_empty CiCheckJob.progress_rows("amcritchie/mcritchie-studio", "never-seen")
  end

  test "[unit] terminal? is true only once completed" do
    assert build_job(status: "completed").terminal?
    assert_not build_job(status: "in_progress").terminal?
  end
end
