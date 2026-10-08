# frozen_string_literal: true

require "test_helper"

# Task::DEVOPS_MIRRORED_KEYS: pr_url, branch, approval_status and session_id live
# both as devops keys and as indexed columns. The key is the write surface, the
# column mirrors it on save, and readers take the column with the key as fallback.
class TaskDevopsMirroredColumnsTest < ActiveSupport::TestCase
  PR_URL = "https://github.com/McRitchie-Studio/mcritchie-studio/pull/4242"

  def task(devops = {})
    Task.create!(title: "mirrored columns sample task", stage: "building",
                 metadata: { "devops" => { "shape" => "backend" }.merge(devops) })
  end

  def columns(record)
    Task::DEVOPS_MIRRORED_KEYS.index_with { |key| record.reload.read_attribute(key) }
  end

  test "[unit] a devops write lands every mirrored key in its column" do
    t = task("pr_url" => PR_URL, "branch" => "feat/x", "approval_status" => "approved", "session_id" => "sess-1")

    assert_equal({ "pr_url" => PR_URL, "branch" => "feat/x", "approval_status" => "approved",
                   "session_id" => "sess-1" }, columns(t))

    t.update!(metadata: t.metadata.deep_merge("devops" => { "session_id" => "sess-2" }))
    assert_equal "sess-2", columns(t)["session_id"]
  end

  test "[unit] a devops write through the API merge path still writes the key" do
    t = task
    merged = Task.merge_devops_into_metadata(t.metadata, { "pr_url" => PR_URL, "approval_status" => "waiting" }, "building")
    t.update!(metadata: merged)

    assert_equal PR_URL, t.reload.devops["pr_url"], "the key stays written for old readers"
    assert_equal PR_URL, t.read_attribute(:pr_url)
    assert_equal "waiting", t.read_attribute(:approval_status)
  end

  test "[unit] clearing a key clears its column" do
    t = task("pr_url" => PR_URL)
    t.update!(metadata: Task.merge_devops_into_metadata(t.metadata, { "pr_url" => "" }))

    assert_nil t.reload.read_attribute(:pr_url)
    assert_nil t.pr_url
  end

  test "[unit] an in-place settle reaches the column on the same save" do
    t = task("approval_status" => "waiting")
    t.update!(stage: "submitted")
    t.update!(stage: "reviewed")

    assert_equal "none", t.reload.devops["approval_status"]
    assert_equal "none", t.read_attribute(:approval_status)
  end

  test "[unit] the column wins over a disagreeing key" do
    t = task("branch" => "feat/old")
    t.update_columns(branch: "feat/new") # rubocop:disable Rails/SkipsModelValidations

    assert_equal "feat/new", t.reload.branch
  end

  test "[unit] a reader falls back to the key while the column is blank" do
    t = task("pr_url" => PR_URL, "approval_status" => "approved", "session_id" => "sess-9", "branch" => "feat/y")
    t.update_columns(Task::DEVOPS_MIRRORED_KEYS.index_with(nil)) # rubocop:disable Rails/SkipsModelValidations
    t.reload

    assert_equal PR_URL, t.pr_url
    assert_equal PR_URL, t.devops_url("pr")
    assert_equal "approved", t.approval_status
    assert_equal "sess-9", t.devops_session_id
    assert_equal "feat/y", t.branch
    assert_equal PR_URL, t.as_json["pr_url"], "the API's top-level field reads the fallback too"
  end

  test "[unit] a select that omits the columns reads the keys" do
    t = task("pr_url" => PR_URL, "branch" => "feat/partial")
    partial = Task.where(id: t.id).select(:id, :slug, :metadata).first

    assert_equal PR_URL, partial.pr_url
    assert_equal "feat/partial", partial.branch
    assert_equal "mcritchie-studio", partial.release_repo
  end

  test "[unit] an attribute write sets the column and the key" do
    t = task
    t.update!(pr_url: " #{PR_URL} ", approval_status: "approved")

    assert_equal PR_URL, t.reload.read_attribute(:pr_url)
    assert_equal PR_URL, t.devops["pr_url"]
    assert_equal "approved", t.devops["approval_status"]

    t.update!(pr_url: nil)
    assert_nil t.reload.read_attribute(:pr_url)
    assert_not t.devops.key?("pr_url")
  end

  test "[unit] an attribute write survives a metadata hash in the same assignment" do
    t = Task.create!(title: "mirrored columns sample task", stage: "building",
                     pr_url: PR_URL, metadata: { "devops" => { "shape" => "backend" } })

    assert_equal PR_URL, t.reload.read_attribute(:pr_url)
    assert_equal PR_URL, t.devops["pr_url"]
    assert_equal "backend", t.devops["shape"]
  end

  test "[unit] an invalid approval_status is a validation error, not a stored value" do
    t = task
    t.metadata = t.metadata.deep_merge("devops" => { "approval_status" => "maybe" })

    assert_not t.save
    assert_includes t.errors[:approval_status].join, "must be one of"
    assert_nil t.reload.read_attribute(:approval_status)
  end

  test "[unit] a legacy odd value does not brick an unrelated save" do
    t = task
    t.update_columns(approval_status: "legacy", metadata: t.metadata.deep_merge("devops" => { "approval_status" => "legacy" })) # rubocop:disable Rails/SkipsModelValidations

    assert t.reload.update(title: "mirrored columns renamed task")
  end

  test "[unit] mirrored keys stay writable; the column-only names still raise" do
    assert_equal [], Task::DEVOPS_MIRRORED_KEYS & Task::DEVOPS_COLUMN_KEYS.keys,
                 "a retired key moves to DEVOPS_COLUMN_KEYS only once old writers are gone"
    assert_nothing_raised { Task.normalize_devops_metadata("pr_url" => PR_URL, "branch" => "feat/z") }
    assert_raises(ArgumentError) { Task.normalize_devops_metadata("release_slug" => "x") }
  end

  test "[unit] the stale-approval settle moves the column with the key" do
    t = task("approval_status" => "waiting")
    t.update_columns(stage: "shipped") # rubocop:disable Rails/SkipsModelValidations

    assert_equal [t.slug], Task.settle_stale_operator_approvals!
    assert_equal "none", t.reload.read_attribute(:approval_status)
    assert_equal "none", t.devops["approval_status"]
  end

  test "[integration] the board sorts waiting approvals first by the column" do
    plain = task
    waiting = task
    waiting.update_columns(approval_status: "waiting") # rubocop:disable Rails/SkipsModelValidations
    plain.update_columns(position: 999_999) # rubocop:disable Rails/SkipsModelValidations

    ordered = Task.where(id: [plain.id, waiting.id]).ordered.to_a
    assert_equal [waiting.id, plain.id], ordered.map(&:id), "the CASE reads tasks.approval_status"
  end

  test "[unit] a create seeds the branch column from a readable slug" do
    t = Task.create!(title: "branch seed sample task", slug: "branch-seed-sample", metadata: {})

    assert_equal "feat/branch-seed-sample", t.reload.read_attribute(:branch)
  end
  # Regression: resync_session_mascots! wrote the metadata it loaded at the start
  # of its loop with update_columns, so a pr_url, branch, approval_status or
  # session_id another writer saved meanwhile went back in the key while the
  # column kept the new value.
  test "[integration] resync_session_mascots! leaves the four columns equal to their keys" do
    Pokemon.create!(dex: 1, name: "Resync", slug: "resync-mon", generation: 1)
    t = task("session_id" => "sess-resync", "pr_url" => PR_URL, "branch" => "feat/old",
             "approval_status" => "waiting")
    # An old mascot stamp, so the resync restamps this row.
    t.update_columns(metadata: t.metadata.deep_merge("devops" => { "mascot" => "resync-mon", "mascot_session" => "old" })) # rubocop:disable Rails/SkipsModelValidations
    newer_pr = "#{PR_URL}0"

    # Another writer saves between the resync's read and its write.
    concurrent = lambda do |*|
      Task.find(t.id).update!(pr_url: newer_pr, branch: "feat/new", approval_status: "approved")
      nil
    end
    SessionMascot.stub(:find_by, concurrent) { assert_equal 1, Task.resync_session_mascots! }

    t.reload
    Task::DEVOPS_MIRRORED_KEYS.each do |key|
      assert_equal t.devops[key].to_s.strip.presence, t.read_attribute(key), "#{key}: column equals key"
    end
    assert_equal newer_pr, t.devops["pr_url"], "the concurrent write survives the restamp"
    assert_equal "approved", t.read_attribute(:approval_status)
    assert_equal "sess-resync", t.devops["mascot_session"]
  end
end
