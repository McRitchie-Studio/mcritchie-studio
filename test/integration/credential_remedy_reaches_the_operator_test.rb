require "test_helper"
require "open3"
require "tmpdir"

# [integration] The remedy must survive the whole way to the operator's terminal.
#
# WHY THIS TIER EXISTS AND THE UNIT TESTS DO NOT COVER IT. The unit tests call
# `OpVaults.diagnose` directly, and the command tests drive the shell helper. Both
# pass even if `bin/gh-token` — the command an agent ACTUALLY runs — never surfaces
# the diagnosis: it composes its own sentence around it, and a caller that stopped
# printing `diagnose` (or printed a stale string of its own) would break the fix
# while every unit test stayed green. So this runs the real binary, in a real
# process, and reads what a human would see.
#
# WHAT WENT WRONG (2026-08-30). The old refusal said "Run this from the admin lane,
# or install the token with bin/setup-1pass-token --admin." The first half names no
# command; the second is an INSTALL that prompts the operator for a credential.
# On a machine provisioned two days earlier, an agent read that, concluded the
# deployer lane was not self-service, and put a hand-mint chore on Mr. McRitchie
# while a production deploy waited. `source ~/.zprofile.admin` was the whole fix.
class CredentialRemedyReachesTheOperatorTest < ActiveSupport::TestCase
  GH_TOKEN = Rails.root.join("bin/gh-token").to_s

  test "a provisioned machine is told the line to run, through the real command" do
    with_home(provisioned: true) do |err|
      assert_includes err, "source ~/.zprofile.admin",
                      "bin/gh-token must SURFACE the remedy, not merely have one available"
      refute_includes err, "setup-1pass-token",
                      "asking a provisioned machine to install is the operator toil this removes"
    end
  end

  test "an unprovisioned machine is told to install once, through the real command" do
    with_home(provisioned: false) do |err|
      assert_includes err, "setup-1pass-token --admin"
      refute_includes err, "source ~/.zprofile.admin", "sourcing a missing file is a dead end"
    end
  end

  # THE PROPERTY, not two example strings. If a later edit collapses the branches
  # back into one message, this fails even if both strings change — which is how
  # the original single-branch message survived every test it had.
  test "the two machine states never give the same advice" do
    provisioned = with_home(provisioned: true) { |err| err }
    fresh       = with_home(provisioned: false) { |err| err }

    refute_equal provisioned, fresh,
                 "one remedy for both states is the defect: one is self-service, " \
                 "the other is genuinely the operator's"
  end

  private

  # Run the real `bin/gh-token --identity deployer` with HOME pointed at a sandbox,
  # so the provisioned/unprovisioned branch is DRIVEN rather than inherited from the
  # machine the suite happens to run on. (A test that reads the real ~ passes
  # vacuously here — this machine IS provisioned, so half the assertions could
  # never fail. That mistake was made once already on this task and caught by
  # mutation.) OP_ADMIN_SERVICE_ACCOUNT_TOKEN is cleared so the lane genuinely refuses.
  def with_home(provisioned:)
    Dir.mktmpdir do |home|
      File.write(File.join(home, ".zprofile.admin"), "# token would be here\n") if provisioned
      _out, err, status = Open3.capture3(
        { "HOME" => home, "OP_ADMIN_SERVICE_ACCOUNT_TOKEN" => nil },
        GH_TOKEN, "--identity", "deployer"
      )
      refute status.success?, "the deployer lane must REFUSE without its token"
      yield err
    end
  end
end
