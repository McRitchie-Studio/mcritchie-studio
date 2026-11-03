module AgentChat
  # Who is reading the chat, as a tier the agent's prompt reads
  # (AgentContextBuilder#viewer_rule). It sets the agent's tone only and grants
  # nothing: the audience stays the public and the role stays the person's
  # (AgentChat::Ingest).
  #
  #   visitor  not signed in        sell them on using the agent
  #   member   signed in            show them how to use the product more
  #   admin    an admin of the app  a normal helpful agent
  #
  # The server names it, never the browser: the hub's session, or on a satellite
  # the app that holds the credential.
  module Viewer
    TIERS = %w[visitor member admin].freeze

    module_function

    def for_user(user)
      return "visitor" unless user

      user.respond_to?(:admin?) && user.admin? ? "admin" : "member"
    end

    # What a satellite sent. Anything unknown is the lowest tier its sign-in
    # allows, so an engine that sends no tier reads visitor or member.
    def normalize(value, signed_in: false)
      tier = value.to_s
      return tier if TIERS.include?(tier)

      signed_in ? "member" : "visitor"
    end
  end
end
