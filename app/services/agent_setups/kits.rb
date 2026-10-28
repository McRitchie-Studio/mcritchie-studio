module AgentSetups
  # The registry of step kits: one per AgentSetup kind. A kit names its steps in
  # order, the public details a new setup starts with, what blocks Done, and the
  # check the hub runs after Done (AgentSetupCheckJob). The card renders a kit's
  # steps through its partial, agent_setups/kits/_<kind>.
  #
  # A new kind (Gmail delegation, a wallet, QuickBooks) is a kit here, a partial,
  # and the kind added to the agent_setups_kind_known check constraint.
  module Kits
    REGISTRY = { "discord_bot" => "AgentSetups::DiscordBotKit" }.freeze

    module_function

    def kinds = REGISTRY.keys

    def fetch(kind)
      name = REGISTRY.fetch(kind.to_s) { raise ArgumentError, "unknown setup kind #{kind.inspect} (known: #{kinds.join(', ')})" }
      name.constantize
    end
  end
end
