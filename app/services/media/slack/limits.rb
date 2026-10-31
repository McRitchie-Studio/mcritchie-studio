module Media
  class Slack < Adapter
    # Slack's noise caps: the shared Media::Limits (config/agent_media.yml
    # `limits:`) counted over Slack's rows of the outbound ledger, with Alex
    # McRitchie's Slack user (config/agent_routes.yml slack.owner_user_id) as
    # the owner whose messages reset a thread and whose questions are never
    # noise.
    class Limits < Media::Limits
      def self.current(config: Media::Config.current, owner_user_id: owner_id)
        new((config.respond_to?(:limits) ? config.limits : {}), owner_user_id: owner_user_id)
      end

      def self.owner_id
        AgentMessages::SlackRoutes.current.owner_user_id
      rescue StandardError
        nil
      end

      def initialize(config = {}, owner_user_id: nil)
        super(config, owner_user_id: owner_user_id, medium: "slack")
      end
    end
  end
end
