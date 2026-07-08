require "application_system_test_case"

class TaskApprovalExitSystemTest < ApplicationSystemTestCase
  test "[e2e] submitted task no longer shows waiting approval" do
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
    assert_no_selector "#card-#{task.slug} [data-test='operator-approval-waiting']"
  end
end
