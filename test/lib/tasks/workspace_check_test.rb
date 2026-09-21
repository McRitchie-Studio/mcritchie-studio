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

  # A SYNTHETIC secret, shaped like the thing that would actually be quoted back:
  # a PEM body. Never a real key, and the assertions below never print it.
  LEAK_MARKER = "SYNTHETICPRIVATEKEYBODY0123456789".freeze

  # THE ASSERTIONS ARE PLAIN `refute`, DELIBERATELY. minitest's `message()`
  # prepends a custom message and still APPENDS the default one, so
  # `refute_includes` dumps its haystack even when you pass your own message —
  # which, for a leak test, prints the very bytes it is asserting the absence
  # of. Only plain `assert`/`refute` suppress the default. So: no haystack in
  # any message below, and lengths instead of contents.
  test "a CHECK FAILED row does not print what the exception was quoting" do
    WorkspaceAccount.create!(domain: "quoting.test")
    quoting = ->(_subject) {
      raise JSON::ParserError, "unexpected token at '{\"private_key\":\"#{LEAK_MARKER}\"}'"
    }

    _out, err = run_check(nil, probe: quoting)

    assert err.include?("CHECK FAILED"), "the sweep must still report the failure"
    refute err.include?(LEAK_MARKER),
           "the CHECK FAILED line carried #{LEAK_MARKER.length} bytes the exception was quoting; " \
           "stderr was #{err.length} chars"
    assert err.include?("JSON::ParserError"),
           "the operator still needs to know WHICH error — the class is the part that is safe"
  end

  # The other half: redaction must not throw away the one thing an operator
  # acts on. An OAuth refusal names its reason in a JSON body, and that slug is
  # the whole diagnosis — a rescue that reports only the class turns
  # "unauthorized_client" into "Signet::AuthorizationError" and costs the reader
  # the answer.
  test "an OAuth refusal still surrenders the slug the operator acts on" do
    WorkspaceAccount.create!(domain: "slug.test")
    refusing = ->(_subject) {
      raise RuntimeError, %({"error": "unauthorized_client", "error_description": "#{LEAK_MARKER}"})
    }

    _out, err = run_check(nil, probe: refusing)

    assert err.include?("unauthorized_client"), "the actionable slug must survive redaction"
    refute err.include?(LEAK_MARKER),
           "the description field carried #{LEAK_MARKER.length} bytes through; " \
           "stderr was #{err.length} chars"
  end
end
