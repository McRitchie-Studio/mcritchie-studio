# The hub's half of a pending agent's check, queued by Alex McRitchie's Done on
# its card (AgentSetupsController#submit; SOP
# docs/agents/agents/steffon/sops/agent-onboarding.md).
#
# THE SPLIT. The hub dyno holds no 1Password right and never sees the new
# bot's token, so it checks only what it can (the kit's hub_check: for a
# Discord bot, the application id and the bot's membership of the server,
# asked through the agents' shared bot) and then marks the card "waiting for
# Steffon". The token read, Discord's GET /users/@me, and the install as
# DISCORD_BOT_TOKEN_<SOUL> are Steffon's `bin/agent-setup verify` on the Mac,
# which reports back through AgentSetups::Command; that report re-checks the
# installed token from the dyno's own environment before marking it ready.
#
# A setup no longer `checking` (closed, or checked by an earlier run) is left
# alone. ANY fault in the check leaves the card on needs_attention, never stuck
# on checking (which has no Done button): a Discord fault (timeout, 5xx, rate
# limit) and any other error (a bad config, a bug in a kit) are recorded in
# /error_logs, targeted at the setup, and the card says what happened; Done
# retries.
class AgentSetupCheckJob < ApplicationJob
  queue_as :default

  def perform(setup_id)
    setup = AgentSetup.find_by(id: setup_id)
    return unless setup&.status == "checking"

    verdict, note = setup.kit.hub_check(setup)
    verdict == :verifying ? setup.await_verify!(note) : setup.needs_attention!(note)
  rescue AgentMessages::DiscordBot::Error => e
    stop(setup, e, "The hub could not reach Discord to check the bot (#{e.class.name.demodulize}). Press Done to try again.")
  rescue StandardError => e
    stop(setup, e, "The hub's check failed (#{e.class.name.demodulize}, recorded in /error_logs). Press Done to try again; " \
                   "if it fails the same way, ask Steffon.")
  end

  private

  # Log first (a failed log never raises), then move the card, so a fault in
  # the move itself still left its cause in /error_logs.
  def stop(setup, error, reason)
    if setup
      setup.log_error!(error, "hub check after Done")
      setup.needs_attention!(reason)
    else
      ErrorLog.capture!(error)
    end
  end
end
