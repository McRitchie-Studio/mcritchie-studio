# Tells the team's Discord that Alex filed an upgrade proposal
# (AgentProposals::Upgrade), so Alex McRitchie sees it without watching a page.
# Where it posts is the upgrade_proposals home in config/agent_media.yml
# (discord #internal, the DISCORD_INTERNAL_WEBHOOK_URL lane), through Media.post,
# as AppRequestDiscordJob does for a /build request.
#
# Best effort: an outage or a missing webhook never costs the proposal, which
# waits on /admin/upgrade_proposals either way. The nonce lets Discord drop a
# retried post. The embed names the tier, billing, the app the person named and
# the review page; never the person's email or the chat's words.
class UpgradeProposalNoticeJob < ApplicationJob
  queue_as :default

  EMBED_COLOR = 0x8E83FC

  def self.home = Media.home(purpose: :upgrade_proposals)

  def perform(proposal_id)
    proposal = AgentProposal.find_by(id: proposal_id, kind: AgentProposals::Upgrade::KIND)
    return if proposal.nil? || proposal.status != "proposed"

    home = self.class.home
    unless home&.channel? && (home.medium != "discord" || home.webhook_url)
      Rails.logger.info("[upgrade_proposal_notice] #{home ? home.label : 'config/agent_media.yml upgrade_proposals'} is unset; proposal #{proposal.id} waits on the review page")
      return
    end

    Media.post(home, embeds: [ self.class.embed(proposal) ], nonce: "upgrade-proposal-#{proposal.id}")
  rescue Media::Error => e
    Rails.logger.warn("[upgrade_proposal_notice] post for proposal #{proposal_id} failed (#{e.class})")
  end

  # The message, built separately so it can be tested without a network.
  def self.embed(proposal)
    base = "https://#{ENV.fetch('APP_HOST', 'mcritchie.studio')}"
    params = proposal.params.to_h
    signed_in = AgentProposals::Upgrade.user_for(proposal) ? "yes" : "no (a visitor)"
    fields = [
      { name: "Tier", value: AgentProposals::Upgrade.tier_name(params["tier"]), inline: true },
      { name: "Billing", value: params["billing"].to_s.presence || "monthly", inline: true },
      { name: "Signed in", value: signed_in, inline: true }
    ]
    fields << { name: "App named", value: params["app"].to_s, inline: true } if params["app"].present?
    fields << { name: "Review", value: "#{base}/admin/upgrade_proposals", inline: false }
    {
      title: "Alex proposes an upgrade to #{AgentProposals::Upgrade.tier_name(params['tier'])}",
      description: proposal.summary.to_s,
      color: EMBED_COLOR,
      fields: fields,
      timestamp: proposal.created_at.iso8601
    }
  end
end
