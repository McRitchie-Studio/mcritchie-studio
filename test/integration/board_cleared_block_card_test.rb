require "test_helper"

# [integration] the board renders the cleared-block re-review state end-to-end:
# a task that was QA-blocked, had the block resolved (a resolves_feedback handoff),
# and sits back in `submitted` gets the amber tone — not red, not plain. The old
# RE-REVIEW badge was dropped as redundant with this tone. Exercises the
# controller's @ever_blocked_slugs preload feeding Task#block_state through the
# real _board/_task_card partials.
class BoardClearedBlockCardTest < ActionDispatch::IntegrationTest
  test "a resolved block back in submitted shows the amber re-review card (tone, no badge)" do
    task = Task.create!(title: "board cleared block card", stage: "submitted")
    Activity.create!(task_slug: task.slug, activity_type: "qa_feedback", description: "please fix Y")
    Activity.create!(task_slug: task.slug, activity_type: "handoff", description: "fixed Y",
                     metadata: { "resolves_feedback" => true })

    get tasks_path
    assert_response :success

    assert_select "#card-#{task.slug}.bg-amber-50"
    assert_select "#card-#{task.slug} [data-test='cleared-feedback']", { count: 0 }, "the RE-REVIEW badge is dropped; the amber tone carries it"
    assert_select "#card-#{task.slug} [data-test='unresolved-feedback']", count: 0
  end

  test "an unresolved block stays red, not amber" do
    task = Task.create!(title: "board still blocked card", stage: "submitted")
    Activity.create!(task_slug: task.slug, activity_type: "qa_feedback", description: "still broken")

    get tasks_path
    assert_response :success

    assert_select "#card-#{task.slug}.bg-red-50"
    assert_select "#card-#{task.slug} [data-test='cleared-feedback']", count: 0
  end

  test "a never-blocked submitted card stays plain (no amber, no badge)" do
    task = Task.create!(title: "board never blocked card", stage: "submitted")

    get tasks_path
    assert_response :success

    assert_select "#card-#{task.slug}.bg-surface"
    assert_select "#card-#{task.slug} [data-test='cleared-feedback']", count: 0
  end
end
