module AgentSetups
  # Discord permission flags by name, and the bitset a named set sums to
  # (https://discord.com/developers/docs/topics/permissions). Only the flags a
  # set in config/agent_setups.yml uses are listed; an unknown name raises, so
  # a typo cannot silently drop a permission from an invite.
  module DiscordPermissions
    # The flags DiscordDirectory::Permissions already names are its constants, so
    # the two never disagree; the rest are Discord's documented bits.
    FLAGS = {
      "manage_channels" => 1 << 4,
      "view_channel" => DiscordDirectory::Permissions::VIEW_CHANNEL,
      "send_messages" => DiscordDirectory::Permissions::SEND_MESSAGES,
      "embed_links" => DiscordDirectory::Permissions::EMBED_LINKS,
      "read_message_history" => 1 << 16,
      "manage_roles" => 1 << 28,
      "manage_webhooks" => 1 << 29,
      "send_messages_in_threads" => DiscordDirectory::Permissions::SEND_MESSAGES_IN_THREADS
    }.freeze

    module_function

    def bits(names)
      Array(names).sum { |name| FLAGS.fetch(name.to_s) { raise ArgumentError, "unknown Discord permission #{name.inspect}" } }
    end
  end
end
