# frozen_string_literal: true

# [unit] What `bin/release ship` tells an operator when a push is refused on AUTH.
#
#   ruby -Itest test/lib/release_auth_remedy_message_test.rb
#
# THE INCIDENT THIS PINS, 2026-08-30. A production ship was refused on credentials.
# The message named the FILE — "~/.zprofile.admin, installed by
# bin/setup-1pass-token --admin" — while PRESCRIBING THE INSTALL, which prompts the
# operator for a credential they had already supplied two days earlier. An agent read
# it, concluded the ship lane was not self-service, and put a hand-mint chore on Mr.
# McRitchie while the deploy waited. `source ~/.zprofile.admin` was the whole fix.
#
# A refusal that names the wrong remedy is worse than one that names none: the reader
# ACTS on it. That is why these assertions are about ORDER as much as content — the
# install is still named, because a machine that has never been provisioned genuinely
# needs it, but it must come second and conditionally.
#
# WHY THIS FILE EXISTS SEPARATELY. `release_cli_test.rb` is the suite's worst APPEND
# hotspot — 7,598 lines, touched by 26 of the last 200 PRs, all colliding at the
# bottom of one file — and the test-health ratchet refuses further growth by design.
# It offers two outs: a new file named for its concern, or a documented ceiling raise.
# This ceiling had already been raised four times; a fifth would have been the wrong
# answer to a guard doing its job. `eval_helper` is re-implemented here rather than
# shared, exactly as test/lib/release_consumer_checkout_test.rb does.
require "minitest/autorun"
require "open3"
require_relative "../support/session_env"

class ReleaseAuthRemedyMessageTest < Minitest::Test
  BIN = File.expand_path("../../bin/release.rb", __dir__)

  def test_the_auth_message_leads_with_the_self_service_command
    msg = eval_helper(%(push_failure_message("mcritchie-studio", "a" * 40, :auth)))

    assert_includes msg, "source ~/.zprofile.admin",
                    "on a provisioned machine this one line IS the fix; a message that omits " \
                    "it converts a self-service failure into operator toil"
    assert_operator msg.index("source ~/.zprofile.admin"), :<, msg.index("bin/setup-1pass-token"),
                    "the install must come SECOND and conditionally — leading with it sends a " \
                    "provisioned machine on the wrong errand, which is what cost the session"
    assert_match(/export GH_APP_ITEM=github\.mcritchie-deployer/, msg)
    assert_operator msg.index("export GH_APP_ITEM"), :>, msg.index("source ~/.zprofile.admin"),
                    "GH_APP_ITEM must be exported BEFORE minting but AFTER sourcing; printed the " \
                    "other way round the reader mints the AGENT token and calls it a success"
  end

  # THE CONTROL. If `push_failure_message` stopped distinguishing causes, the test
  # above could pass on a message that says the same thing for every failure — which
  # would be its own defect. A DIVERGENCE is not an auth problem and must not
  # prescribe a credential remedy.
  def test_a_divergence_is_not_given_the_credential_remedy
    msg = eval_helper(%(push_failure_message("mcritchie-studio", "a" * 40, :diverged)))

    refute_includes msg, "source ~/.zprofile.admin",
                    "prescribing a credential fix for a diverged branch is the same class of " \
                    "wrong-remedy defect this file exists to prevent"
  end

  # MOVED HERE from release_cli_test.rb, which is the suite's worst append hotspot
  # and at its ratchet ceiling. This assertion is purely about the AUTH MESSAGE,
  # so it belongs in the file named for that concern rather than at the bottom of
  # a 7,598-line general file — which is exactly what the ratchet asks for.
  #
  # THE MESSAGE, not just the label — the label is only useful if the sentence the
  # operator reads changes with it. The auth message must not send anyone to
  # reconcile a branch or re-run `prepare`: re-freezing a good freeze is the waste
  # the misdiagnosis actually cost.
  def test_the_auth_message_names_the_deployer_lane_and_never_asks_for_a_re_freeze
    msg = eval_helper(%(push_failure_message("mcritchie-studio", "a" * 40, :auth)))

    assert_includes msg, "REFUSED ON CREDENTIALS"
    # REBOUND, not loosened: this pinned a literal remedy that was itself the bug
    # (bare, it printed a LIVE deployer token and could not fix the caller's
    # shell). The concern underneath — name the DEPLOYER lane, never the
    # agent-lane refresh — is what is asserted now.
    assert_includes msg, "DEPLOYER identity",
                    "the ship lane pushes as the DEPLOYER — a message that does not say so " \
                    "invites the agent-lane refresh, which is the wrong command"
    assert_includes msg, "source ~/.zprofile.admin",
                    "on a provisioned machine that one line IS the remedy"
    refute_includes msg, "gh-auth-refresh",
                    "prescribing a refresh here leaks a live token AND cannot fix the caller's " \
                    "shell; the deployer is never cached, so the next push mints on its own"
    assert_includes msg, "OP_ADMIN_SERVICE_ACCOUNT_TOKEN",
                     "minting a deployer token reads agents-admin, which an ordinary agent shell cannot"
    assert_includes msg, "has NOT diverged"
    refute_match(/re-run `bin\/release prepare`/, msg,
                 "the freeze is still good — sending the operator back through prepare is the exact " \
                 "waste this classification exists to stop")
  end


  private

  # Re-implemented rather than shared: release_cli_test.rb's copy is private to that
  # file, and importing it would re-couple this concern to the hotspot.
  def eval_helper(expr)
    out, err, status = Open3.capture3(
      SessionEnv.neutralized({}), "ruby", "-e", %(load #{BIN.inspect}; print(#{expr}))
    )
    assert_predicate status, :success?, "bin/release must load standalone: #{err}"
    out
  end
end
