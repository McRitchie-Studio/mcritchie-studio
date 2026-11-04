require "test_helper"
require "rake"

# [unit] workspace:folder_user changes the folder user and nothing else: re-running
# register would re-stamp the scopes, which hides scope drift.
class WorkspaceFolderUserRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("workspace:folder_user")
    Rake::Task["workspace:folder_user"].reenable
  end

  test "it sets the folder user and leaves the scopes alone" do
    account = WorkspaceAccount.create!(domain: "mason.test", scopes: [ "old-scope" ])
    capture_io { Rake::Task["workspace:folder_user"].invoke("mason.test", "Owner@Mason.test") }

    account.reload
    assert_equal "owner@mason.test", account.folder_user_email
    assert_equal [ "old-scope" ], account.scopes
  end

  test "it refuses a domain nobody registered" do
    assert_raises(SystemExit) { capture_io { Rake::Task["workspace:folder_user"].invoke("nobody.test", "owner@nobody.test") } }
  end
end
