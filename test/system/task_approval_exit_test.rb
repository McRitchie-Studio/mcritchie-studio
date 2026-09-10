require "application_system_test_case"

# The operator-approval request's life on the rendered board, end to end. It used to
# assert the bar was gone at `submitted`; that was the 2026-09-09 defect written down
# as a guarantee — `bin/ship` discarded requests the documented flow told builders to
# set, so a builder who asked for Mr. McRitchie's eyes got none. The exit is now the
# MERGE, and both halves are driven here in one browser session.
class TaskApprovalExitSystemTest < ApplicationSystemTestCase
  test "[e2e] a submitted task still shows waiting approval, and a reviewed one does not" do
    task = Task.create!(
      title: "approval exit system",
      stage: "building",
      metadata: {
        "devops" => {
          "approval_status" => "waiting",
          "local_url" => "http://localhost:3001/demo"
        }
      }
    )
    task.submit!

    visit tasks_path

    assert_selector "#card-#{task.slug}", text: "approval exit system"
    assert_selector "#card-#{task.slug} [data-test='operator-approval-waiting']",
                    text: "WAITING APPROVAL"

    # Review merges the PR onto `accepted` and moves the card to `reviewed`, where
    # the desk serving the local demo is reclaimable — so the CTA has to go. Read on
    # the deployments board, the only one with a `reviewed` column.
    task.review!

    visit deployments_path

    assert_selector "#card-#{task.slug}", text: "approval exit system"
    assert_no_selector "#card-#{task.slug} [data-test='operator-approval-waiting']"
  end
end
