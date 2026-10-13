# Shared builders for the agent mailbox tests (docs/agents/system/agent-message-loop.md).
# Ids are fake snowflakes; nothing here reaches Discord.
module AgentMessageFixtures
  GUILD = "900000000000000001".freeze
  DESK = "900000000000000002".freeze
  QUIET = "900000000000000003".freeze
  AVI_ROLE = "900000000000000010".freeze
  XAN_ROLE = "900000000000000011".freeze
  AVI_BOT = "900000000000000020".freeze
  SHARED_BOT = "900000000000000099".freeze

  def agent_routes(default_soul: nil)
    AgentMessages::Routes.new(
      "discord" => {
        "bot_user_id" => SHARED_BOT,
        "guilds" => {
          GUILD => {
            "name" => "McRitchie",
            "channels" => { DESK => { "name" => "agent-desk", "default_soul" => default_soul.to_s },
                            QUIET => { "name" => "quiet" } },
            "souls" => { "avi" => { "roles" => [ AVI_ROLE ], "users" => [ AVI_BOT ] },
                         "xan" => { "roles" => [ XAN_ROLE ], "users" => [] } }
          }
        }
      }
    )
  end

  # A Discord message object as GET /channels/{id}/messages returns it.
  def discord_raw(id, content:, channel: DESK, author: "500", bot: false, roles: [], users: [], reply_to: nil,
                  at: Time.current)
    raw = {
      "id" => id.to_s, "type" => reply_to ? 19 : 0, "channel_id" => channel, "content" => content,
      "author" => { "id" => author, "username" => "alex", "global_name" => "Alex", "bot" => bot },
      "mentions" => users.map { |u| { "id" => u } }, "mention_roles" => roles,
      "timestamp" => at.iso8601
    }
    raw["message_reference"] = { "message_id" => reply_to.to_s } if reply_to
    raw
  end

  @@agent_message_seq = 0

  def agent_message!(soul: "avi", thread_key: nil, status: "received", **attrs)
    @@agent_message_seq += 1
    ext = "7#{Process.pid}#{@@agent_message_seq}#{rand(1_000_000)}"
    AgentMessage.create!({ channel: "discord", external_id: ext, guild_id: GUILD, channel_ref: DESK,
                           thread_key: thread_key || "discord:#{DESK}:#{ext}", author_name: "Alex",
                           content: "hello #{soul}", soul_slug: soul, routed_by: "role", status: status }.merge(attrs))
  end
end
