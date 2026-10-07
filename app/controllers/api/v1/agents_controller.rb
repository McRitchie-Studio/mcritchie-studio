module Api
  module V1
    # An agent update writes its config and metadata, so it is an admin-tier write:
    # a studio session answers 403 with the reason (Api::AgentSessionGate). Reads
    # stay open to every bearer.
    class AgentsController < BaseController
      require_admin_session only: :update

      def index
        agents = Agent.all.order(:position)
        result = paginate(agents)
        render_data(result[:records], meta: result[:meta])
      end

      def show
        agent = Agent.find_by!(slug: params[:slug])
        render_data(agent.as_json(methods: [:emoji, :status_color],
                                  include: { skills: { only: [:name, :slug, :category] } }))
      end

      def update
        agent = Agent.find_by!(slug: params[:slug])
        rescue_and_log(target: agent) do
          agent.update!(agent_params)
          render_data(agent)
        end
      rescue StandardError => e
        render_error(e.message)
      end

      private

      def agent_params
        params.permit(:status, :description, :avatar, :title, config: {}, metadata: {})
      end
    end
  end
end
