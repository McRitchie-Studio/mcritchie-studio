require "test_helper"
require "rake"

# [integration] The `workspace:check` sweep — the exact path that could have
# resurrected a revoked workspace. It probes a subject and, on a green probe,
# flips the row active.
#
# Revocation is the one compensating control for holding the impersonation
# allow-list as DATA rather than as a frozen constant, so the proof that it
# holds belongs here, against the trigger, and not only against the model. Note
# what the probe does in every test below: it SUCCEEDS. Revoking locally never
# withdraws the Google-side grant, so a live grant is exactly what a revoked row
# really meets.
class WorkspaceCheckRakeTest < ActiveSupport::TestCase
  KEY = { "client_email" => "sa@synthetic.iam.gserviceaccount.com", "client_id" => "100000000000000000000" }.freeze

  class FakeDrive
    def files_list(query:, limit:) = Struct.new(:files).new([])
  end

  class FakeGmail
    Profile = Struct.new(:email_address, :messages_total)
    def service = self
    def get_user_profile(_who) = Profile.new("team@live.test", 7)
  end

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("workspace:check")
    @probed = []
  end

  # Always green. The dangerous case, and the realistic one.
  def green_probe = ->(subject) { @probed << subject; [ true, nil ] }

  # The sweep calls `exit 1` when any row failed, and that SystemExit is raised
  # INSIDE capture_io — so it has to be caught in there, or the output it was
  # about to hand back is lost with it.
  def run_check(domain = nil, probe: nil)
    probe ||= green_probe
    @exit_status = nil
    Rake::Task["workspace:check"].reenable
    Workspace::Credentials.stub(:configured?, true) do
      Workspace::Credentials.stub(:credential, KEY) do
        Workspace::Credentials.stub(:probe, probe) do
          Workspace::DriveClient.stub(:new, ->(subject:) { FakeDrive.new }) do
            Workspace::GmailClient.stub(:new, ->(subject:) { FakeGmail.new }) do
              capture_io do
                begin
                  Rake::Task["workspace:check"].invoke(domain)
                rescue SystemExit => e
                  @exit_status = e.status
                end
              end
            end
          end
        end
      end
    end
  end

  test "a revoked workspace survives a SUCCESSFUL sweep — never probed, never flipped" do
    # THE BLOCKER. Before the guard, this sweep printed "ACTIVE as
    # team@revoked.test" and reopened a mailbox that had been switched off.
    account = WorkspaceAccount.create!(domain: "revoked.test", status: "revoked")

    out, = run_check

    assert_equal "revoked", account.reload.status
    refute WorkspaceAccount.impersonatable?("team@revoked.test")
    assert_empty @probed, "a revoked row must not even be probed"
    assert_includes out, "SKIPPED"
    refute_includes out, "ACTIVE as team@revoked.test"
  end

  test "naming the revoked domain explicitly does not force it through either" do
    # workspace:check[<revoked-domain>] is the other half of the trigger: an
    # operator asking for that one row by name still does not get it back.
    account = WorkspaceAccount.create!(domain: "named.test", status: "revoked")

    out, = run_check("named.test")

    assert_equal "revoked", account.reload.status
    assert_empty @probed
    assert_includes out, "reinstate"
  end

  test "the skip is per row — a pending workspace beside a revoked one is still proven" do
    revoked = WorkspaceAccount.create!(domain: "off.test", status: "revoked")
    live = WorkspaceAccount.create!(domain: "live.test")

    out, = run_check

    assert_equal "revoked", revoked.reload.status
    assert_equal "active", live.reload.status
    assert_equal [ "team@live.test" ], @probed
    assert_includes out, "ACTIVE as team@live.test"
  end

  test "one row blowing up does not abandon the rest of the sweep half-checked" do
    first = WorkspaceAccount.create!(domain: "aaa-boom.test")
    second = WorkspaceAccount.create!(domain: "zzz-fine.test")
    exploding = ->(subject) {
      @probed << subject
      raise "network gone" if subject.include?("boom")

      [ true, nil ]
    }

    out, err = run_check(nil, probe: exploding)

    assert_equal "pending", first.reload.status, "the row that blew up is left unproven"
    assert_equal "active", second.reload.status, "the row AFTER it was still checked"
    assert_equal [ "team@aaa-boom.test", "team@zzz-fine.test" ], @probed
    assert_includes err, "CHECK FAILED"
    assert_includes out, "ACTIVE as team@zzz-fine.test"
    assert_equal 1, @exit_status, "a sweep with a failed row still exits non-zero"
  end
end
