module Media
  class Teams < Adapter
    # Teams' noise caps: the shared Media::Limits (config/agent_media.yml
    # `limits:`, the same numbers as Slack's) counted over Teams' rows of the
    # outbound ledger, with Alex McRitchie's Entra object id
    # (config/agent_routes.yml teams.owner_aad_object_id) as the owner. Until it
    # is set no message is his, so the thread cap never resets on Teams and his
    # questions get no exemption: the stricter side.
    class Limits < Media::Limits
      def self.current(config: Media::Config.current, owner_user_id: owner_id)
        new((config.respond_to?(:limits) ? config.limits : {}), owner_user_id: owner_user_id)
      end

      def self.owner_id
        AgentMessages::TeamsRoutes.current.owner_aad_object_id
      rescue StandardError
        nil
      end

      def initialize(config = {}, owner_user_id: nil)
        super(config, owner_user_id: owner_user_id, medium: "teams")
      end
    end
  end
end
