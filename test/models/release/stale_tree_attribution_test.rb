require "test_helper"

# The stale-tree gate's message WITH attribution — the whole point of the change
# is what the operator reads at the moment prepare refuses. Pure: the git state,
# the commit list and the task index are all injected, exactly as bin/release
# gathers them.
#
# ACCEPTANCE 3 IS THE GUARD RAIL HERE: this must NARROW the diagnosis, never
# weaken the refusal. Every case below re-asserts that the verdict is still stale.
class Release::StaleTreeAttributionTest < ActiveSupport::TestCase
  S = Release::StaleTreeCheck

  FEAT_SUBJECT = "Merge pull request #918 from McRitchie-Studio/feat/repair-quarantined-e2e-clusters"
  BATCH_SUBJECT = "Merge pull request #925 from McRitchie-Studio/accepted"

  def stale_state
    [{ "repo" => "mcritchie-studio", "ahead" => 1 }]
  end

  def evaluate(subject:, task_index:)
    S.evaluate(
      accepted_states: stale_state,
      stranded_commits: { "mcritchie-studio" => [{ "sha" => "ad85ec3", "subject" => subject }] },
      repo_nwo: { "mcritchie-studio" => "McRitchie-Studio/mcritchie-studio" },
      release_slug: "rel-20260819-39f42f",
      release_state: "assembling",
      task_index: task_index
    )
  end

  # --- the headline: a lost stamp is named, not guessed ----------------------

  test "a stranded commit whose task exists unstamped is called a LOST STAMP" do
    verdict = evaluate(subject: FEAT_SUBJECT,
                       task_index: { "repair-quarantined-e2e-clusters" =>
                                       { "stage" => "submitted", "merged" => "" } })

    refute verdict["fresh"], "the refusal must stand"
    msg = verdict["message"]
    assert_includes msg, "LOST STAMP"
    assert_includes msg, "repair-quarantined-e2e-clusters"
    assert_includes msg, "bin/task merged repair-quarantined-e2e-clusters accepted"
    assert_includes msg, "bin/task move repair-quarantined-e2e-clusters reviewed"
  end

  test "an all-lost-stamp refusal says the batch PR is not needed" do
    verdict = evaluate(subject: FEAT_SUBJECT,
                       task_index: { "repair-quarantined-e2e-clusters" =>
                                       { "stage" => "submitted", "merged" => "" } })
    assert_includes verdict["message"], "EVERY stranded commit above is a LOST STAMP"
    assert_includes verdict["message"], "do NOT need the hand-landed batch"
  end

  # --- acceptance 3: an unattributable commit aborts exactly as before -------

  test "a commit with no task behind it keeps the original generic diagnosis" do
    verdict = evaluate(subject: BATCH_SUBJECT, task_index: {})

    refute verdict["fresh"]
    msg = verdict["message"]
    assert_includes msg, "no such task behind it"
    refute_includes msg, "LOST STAMP"
  end

  test "a zap commit is not attributed" do
    verdict = evaluate(subject: "zap: record the cap in the fast-cert evidence line", task_index: {})
    refute verdict["fresh"]
    refute_includes verdict["message"], "LOST STAMP"
  end

  # An EMPTY index is what a failed board read produces. It must degrade to the
  # old message rather than claiming anything.
  test "an unreadable task index degrades to the pre-change message" do
    with_index = evaluate(subject: FEAT_SUBJECT, task_index: {})
    refute with_index["fresh"]
    refute_includes with_index["message"], "LOST STAMP"
    assert_includes with_index["message"], "no such task behind it"
  end

  # --- a stamped task is reported, but is still not the promote's problem ----

  test "a stranded commit whose task IS stamped is labelled already attributed" do
    verdict = evaluate(subject: FEAT_SUBJECT,
                       task_index: { "repair-quarantined-e2e-clusters" =>
                                       { "stage" => "reviewed", "merged" => "accepted" } })
    refute verdict["fresh"]
    assert_includes verdict["message"], "already attributed"
    refute_includes verdict["message"], "EVERY stranded commit above is a LOST STAMP"
  end

  # --- mixed: one lost stamp + one orphan keeps the batch-PR recovery --------

  test "a mixed set does not claim every commit is a lost stamp" do
    verdict = S.evaluate(
      accepted_states: [{ "repo" => "mcritchie-studio", "ahead" => 2 }],
      stranded_commits: { "mcritchie-studio" => [
        { "sha" => "aaa1111", "subject" => FEAT_SUBJECT },
        { "sha" => "bbb2222", "subject" => "zap: a hand-landed fix" }
      ] },
      repo_nwo: { "mcritchie-studio" => "McRitchie-Studio/mcritchie-studio" },
      release_slug: "rel-x", release_state: "assembling",
      task_index: { "repair-quarantined-e2e-clusters" => { "stage" => "submitted", "merged" => "" } }
    )

    refute verdict["fresh"]
    msg = verdict["message"]
    assert_includes msg, "LOST STAMP"
    refute_includes msg, "EVERY stranded commit above is a LOST STAMP"
  end

  # --- the fresh path is untouched -------------------------------------------

  test "a level ladder still passes and says nothing about attribution" do
    verdict = S.evaluate(accepted_states: [{ "repo" => "mcritchie-studio", "ahead" => 0 }])
    assert verdict["fresh"]
    refute_includes verdict["message"], "LOST STAMP"
  end
end
