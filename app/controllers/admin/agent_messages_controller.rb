module Admin
  # /admin/agent_messages — the agent mailbox, watched (docs/agents/system/agent-message-loop.md).
  # Every message the Discord poll stored, who it was routed to, who holds the
  # claim and for how long, and the reply. Read-only: workers move messages
  # through the API, not through buttons here.
  class AgentMessagesController < ApplicationController
    before_action :require_admin

    LIMIT = 200

    def index
      @soul = params[:soul].presence
      @status = AgentMessage::STATUSES.include?(params[:status]) ? params[:status] : nil
      @channel = AgentMessage::CHANNELS.include?(params[:channel]) ? params[:channel] : nil

      scope = AgentMessage.newest_first
      scope = scope.for_soul(@soul) if @soul
      scope = scope.with_status(@status) if @status
      scope = scope.on_channel(@channel) if @channel
      @messages = scope.limit(LIMIT)
      @status_counts = AgentMessage.group(:status).count
      @souls = (AgentMessage.where.not(soul_slug: nil).distinct.pluck(:soul_slug) + routed_souls).uniq.sort
      @dispatchers = AgentDispatcher.newest_first.limit(3)
    end

    def show
      @message = AgentMessage.includes(:events).find(params[:id])
    end

    private

    def routed_souls
      AgentMessages::Routes.load.souls
    rescue StandardError
      []
    end
  end
end
