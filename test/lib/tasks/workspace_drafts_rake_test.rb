require "test_helper"
require "rake"

# [integration] The drafting rake tasks, run as the operator runs them.
#
# The property worth a task-level test is ORDER in the acquisition handoff: a
# workspace may be recorded `severed` only after Google itself refuses our
# client id. A probe that still succeeds — or fails for any other reason — must
# leave the row untouched, because "severed" is final and a wrong one cannot be
# taken back.
class WorkspaceDraftsRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("workspace:sever")
    @account = WorkspaceAccount.create!(domain: "acquired.test")
    @account.mark_verified!
    @account.workspace_mailboxes.create!(address: "alex@acquired.test").mark_verified!
  end

  def run_task(task, *args, probe:)
    status = 0
    Rake::Task[task].reenable
    out, err = Workspace::Credentials.stub(:probe, ->(_subject) { probe }) do
      Workspace::Credentials.stub(:credential, { "client_id" => "123" }) do
        capture_io do
          Rake::Task[task].invoke(*args)
        rescue SystemExit => e
          status = e.status
        end
      end
    end
    [ status, out + err ]
  end

  test "sever REFUSES while Google still issues a token" do
    status, output = run_task("workspace:sever", "acquired.test", "acquisition", probe: [ true, nil ])

    refute_equal 0, status
    assert_match(/NOT severed/, output)
    assert_equal "active", @account.reload.status
    assert WorkspaceAccount.impersonatable?("alex@acquired.test", purpose: :mail)
  end

  test "sever REFUSES on a failure that does not prove the grant is gone" do
    status, output = run_task("workspace:sever", "acquired.test", "acquisition", probe: [ false, "SocketError" ])

    refute_equal 0, status
    assert_match(/Revoke now/, output)
    assert_equal "active", @account.reload.status
  end

  test "sever records FINAL once Google refuses our client id, shutting every mailbox" do
    status, output = run_task("workspace:sever", "acquired.test", "acquisition", probe: [ false, "unauthorized_client" ])

    assert_equal 0, status
    assert_match(/SEVERED/, output)
    assert_equal "severed", @account.reload.status
    refute WorkspaceAccount.impersonatable?("alex@acquired.test", purpose: :mail)
  end

  test "check_severed passes only on unauthorized_client" do
    assert_equal 1, run_task("workspace:check_severed", "acquired.test", probe: [ true, nil ]).first
    assert_equal 1, run_task("workspace:check_severed", "acquired.test", probe: [ false, "SocketError" ]).first
    assert_equal 0, run_task("workspace:check_severed", "acquired.test", probe: [ false, "unauthorized_client" ]).first
  end

  test "add_mailbox refuses an address outside a registered workspace" do
    status, output = run_task("workspace:add_mailbox", "alex@unknown.test", probe: [ true, nil ])

    refute_equal 0, status
    assert_match(/No workspace registered for unknown.test/, output)
  end
end
