module Admin
  # /admin/upgrade_proposals: Alex's upgrade proposals (AgentProposals::Upgrade),
  # waiting for the owner's word. Approve sets the tier on an app the person owns
  # (or records the yes for a follow-up); Decline drops it. Nothing here charges
  # anyone. UpgradeProposalNoticeJob pings Discord when one arrives.
  class UpgradeProposalsController < ApplicationController
    before_action :require_admin
    before_action :find_proposal, only: [ :approve, :decline ]
    # A proposal already settled or past its 14 days is told, not logged as an error.
    before_action :require_open, only: [ :approve, :decline ]

    RECENT = 20

    def index
      scope = AgentProposal.where(kind: AgentProposals::Upgrade::KIND).includes(:person, :source_message)
      @open = scope.pending.where("expires_at > ?", Time.current).order(created_at: :desc).to_a
      @recent = scope.where.not(id: @open.map(&:id)).order(updated_at: :desc).limit(RECENT).to_a
    end

    def approve
      settled = rescue_and_log(target: @proposal) { AgentProposals::Upgrade.approve!(@proposal, by: decider) }
      return redirect_to(admin_upgrade_proposals_path, alert: "Approve failed; the error is logged.") unless settled

      result = @proposal.reload.result
      notice = if result["applied"]
        "Approved: #{result['app']} is now on #{AgentProposals::Upgrade.tier_name(result['tier'])}."
      else
        "Approved and recorded. No app this person owns was named, so set the tier by hand."
      end
      redirect_to admin_upgrade_proposals_path, notice: notice
    end

    def decline
      settled = rescue_and_log(target: @proposal) { AgentProposals::Upgrade.decline!(@proposal, by: decider) }
      return redirect_to(admin_upgrade_proposals_path, alert: "Decline failed; the error is logged.") unless settled

      redirect_to admin_upgrade_proposals_path, notice: "Declined. Nothing changed."
    end

    private

    def find_proposal
      @proposal = AgentProposal.find_by!(id: params[:id], kind: AgentProposals::Upgrade::KIND)
    end

    def require_open
      return if AgentProposals::Upgrade.open?(@proposal, Time.current)

      state = @proposal.expired? ? "expired" : @proposal.status
      redirect_to admin_upgrade_proposals_path, alert: "Nothing changed: that proposal is #{state}."
    end

    def decider = "user:#{current_user.slug}"
  end
end
