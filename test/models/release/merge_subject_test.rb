require "test_helper"

# Pure slug recovery from a merge commit subject — no git, no board, no network.
# This is what lets prepare's stale-tree gate say WHICH task a stranded commit
# came from instead of guessing among three causes.
class Release::MergeSubjectTest < ActiveSupport::TestCase
  M = Release::MergeSubject

  FEAT = "Merge pull request #918 from McRitchie-Studio/feat/repair-quarantined-e2e-clusters"
  BATCH = "Merge pull request #925 from McRitchie-Studio/accepted"

  # --- branch + slug recovery ------------------------------------------------

  test "recovers the slug from a real feat merge subject" do
    assert_equal "repair-quarantined-e2e-clusters", M.slug_from_subject(FEAT)
  end

  test "recovers the branch before the slug" do
    assert_equal "feat/repair-quarantined-e2e-clusters", M.branch_from_subject(FEAT)
  end

  test "accepts the other conventional task branch prefixes" do
    %w[feat fix chore bug].each do |prefix|
      subject = "Merge pull request #1 from McRitchie-Studio/#{prefix}/some-task"
      assert_equal "some-task", M.slug_from_subject(subject), "#{prefix}/ should resolve"
    end
  end

  # --- THE EDGE CASE: a rung is not a task -----------------------------------

  # The batch promote PR merges `accepted` itself. Treating that as a slug would
  # invent a task named after a branch of the ladder.
  test "the batch promote PR is never attributed to a task" do
    assert_nil M.slug_from_subject(BATCH)
  end

  test "no ladder rung is ever read as a slug" do
    %w[accepted release main].each do |rung|
      assert_nil M.slug_from_branch(rung), "#{rung} must not resolve"
      assert_nil M.slug_from_subject("Merge pull request #1 from McRitchie-Studio/#{rung}")
    end
  end

  # THE CASE THE PREFIX ALLOW-LIST ACTUALLY EXISTS FOR: a branch that HAS a
  # slash but a foreign prefix. These repos carry many dependabot PRs, and
  # without the allow-list one would resolve to a slug like
  # "bundler/rails-8.1.4" and be looked up as a task.
  test "a third-party branch with a slash is not read as a slug" do
    [
      "Merge pull request #7 from McRitchie-Studio/dependabot/bundler/rails-8.1.4",
      "Merge pull request #8 from McRitchie-Studio/renovate/npm-playwright",
      "Merge pull request #9 from McRitchie-Studio/wip/experiment"
    ].each do |subject|
      assert_nil M.slug_from_subject(subject), subject
    end
  end

  test "an unprefixed branch is not assumed to be a slug" do
    assert_nil M.slug_from_subject("Merge pull request #7 from McRitchie-Studio/hotfix-thing")
  end

  # --- non-merge commits ------------------------------------------------------

  test "a zap or hand-merge subject yields no slug" do
    assert_nil M.slug_from_subject("zap: match the ticket-pointer treatment across both docs")
    assert_nil M.slug_from_subject("")
    assert_nil M.slug_from_subject(nil)
  end

  # --- attribution ------------------------------------------------------------

  test "a task with no merged stamp is a LOST STAMP" do
    index = { "repair-quarantined-e2e-clusters" => { "stage" => "submitted", "merged" => "" } }
    result = M.attribute(FEAT, index)
    assert_equal :lost_stamp, result[:kind]
    assert_equal "repair-quarantined-e2e-clusters", result[:slug]
    assert_equal "submitted", result[:stage]
  end

  test "a task that IS stamped is reported as already attributed" do
    index = { "repair-quarantined-e2e-clusters" => { "stage" => "reviewed", "merged" => "accepted" } }
    result = M.attribute(FEAT, index)
    assert_equal :stamped, result[:kind]
    assert_equal "accepted", result[:merged]
  end

  # A slug the caller could not fetch is UNATTRIBUTABLE, never "unstamped" — an
  # unreadable fact is not a clean fact, and the refusal must stand unchanged.
  test "a slug missing from the index is unattributable, not a lost stamp" do
    assert_equal :unattributable, M.attribute(FEAT, {})[:kind]
    assert_equal :unattributable, M.attribute(FEAT, nil)[:kind]
  end

  test "the batch promote PR is unattributable" do
    assert_equal :unattributable, M.attribute(BATCH, { "accepted" => { "merged" => "" } })[:kind]
  end

  test "symbol keys are tolerated like the rest of the release models" do
    index = { repair_slug: nil, "repair-quarantined-e2e-clusters": { stage: "submitted", merged: "" } }
    assert_equal :lost_stamp, M.attribute(FEAT, index)[:kind]
  end

  test "the repair names both commands" do
    repair = M.lost_stamp_repair("demo-task")
    assert_includes repair, "bin/task merged demo-task accepted"
    assert_includes repair, "bin/task move demo-task reviewed"
  end
end
