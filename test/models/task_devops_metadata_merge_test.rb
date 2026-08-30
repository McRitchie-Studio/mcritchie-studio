require "test_helper"

# The fold Api::V1::TasksController and TasksController BOTH call when a caller
# posts a partial `devops` object (Task.merge_devops_into_metadata).
#
# WHY ITS OWN FILE. The fold used to be a private method on TasksController, so
# the JSON API — the path every agent and every bin/ script writes through — did
# not have it and assigned the metadata column from the posted params instead.
# One field name, two controllers, OPPOSITE semantics. On 2026-08-30 a one-key
# PATCH took a REVIEWED task from 20 devops keys to 8 at HTTP 200, and the lost
# acceptance criteria were the contract that review had been conducted against.
# The contract now has one home in the code and one home in the tests.
#
# The API route itself is driven in test/controllers/api/v1/tasks_controller_test.rb
# ("a partial devops PATCH leaves the devops keys it omits intact"); the board
# form's half lives in test/controllers/tasks_controller_test.rb.
class TaskDevopsMetadataMergeTest < ActiveSupport::TestCase
  # These pin the model-level contract both callers now inherit.

  test "[unit] merge_devops_into_metadata keeps metadata names outside devops" do
    stored = { "devops" => { "kind" => "bug", "agent_context" => "why this exists" },
               "reviewers" => [{ "slug" => "carl", "weight" => "primary" }] }

    merged = Task.merge_devops_into_metadata(stored, "branch" => "feat/x")

    assert_equal [{ "slug" => "carl", "weight" => "primary" }], merged["reviewers"],
                 "a devops post must not touch the rest of the metadata column"
    assert_equal "bug", merged.dig("devops", "kind"), "an unposted devops key survives"
    assert_equal "feat/x", merged.dig("devops", "branch"), "the posted key is authoritative"
  end

  # Presence is the signal Task#devops? and the show page's handoff panel read, so
  # an emptied merge must leave NO key rather than an empty hash.
  test "[unit] merge_devops_into_metadata drops the devops key when the merge empties it" do
    stored = { "devops" => { "branch" => "feat/old" }, "unrelated" => "kept" }

    merged = Task.merge_devops_into_metadata(stored, "branch" => "  ")

    assert_not merged.key?("devops"), "an emptied devops hash must not linger as {}"
    assert_equal "kept", merged["unrelated"]
  end

  # #create reaches the fold with no task, and the result must be exactly the
  # normalized post — the same shape the API's create path relied on before.
  test "[unit] merge_devops_into_metadata starts from an empty base when there is no metadata" do
    merged = Task.merge_devops_into_metadata(nil, "kind" => "feature")

    assert_equal({ "devops" => { "kind" => "feature" } }, merged)
  end

  # Pure: the caller's stored hash is never written through, or a failed save
  # would leave a half-applied merge on the in-memory record.
  test "[unit] merge_devops_into_metadata does not mutate the hash it is given" do
    stored = { "devops" => { "kind" => "bug" }, "unrelated" => "kept" }

    Task.merge_devops_into_metadata(stored, "kind" => "feature")

    assert_equal({ "devops" => { "kind" => "bug" }, "unrelated" => "kept" }, stored,
                 "the stored hash must not be mutated in place")
  end
end
