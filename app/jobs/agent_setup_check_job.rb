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
# alone. A Discord fault (timeout, 5xx, rate limit) is recorded on the card and
# in /error_logs, and the card says so; Done retries.
class AgentSetupCheckJob < ApplicationJob
  queue_as :default

  def perform(setup_id)
    setup = AgentSetup.find_by(id: setup_id)
    return unless setup&.status == "checking"

    verdict, note = setup.kit.hub_check(setup)
    verdict == :verifying ? setup.await_verify!(note) : setup.needs_attention!(note)
  rescue AgentMessages::DiscordBot::Error => e
    ErrorLog.capture!(e)
    setup&.needs_attention!("The hub could not reach Discord to check the bot (#{e.class.name.demodulize}). Press Done to try again.")
  end
end
