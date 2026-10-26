# Shared builders for the agent mailbox tests (docs/agents/system/agent-message-loop.md).
# Ids are fake snowflakes; nothing here reaches Discord.
module AgentMessageFixtures
  # The owner-only guard switched OFF: every person may be answered. Most mailbox
  # tests are about claims, threads and memory, not about who may speak, and
  # their rows carry made-up authors (or none). The guard's own tests
  # (test/models/agent_message_held_test.rb, test/integration/agent_owner_only_guard_test.rb)
  # install the real config/agent_answerers.yml, or a list of their own, instead.
  class UnguardedAnswerers
    def person_ids = []
    def roles = AgentPerson::ROLES
    def held_reason(_person) = "unguarded"
    def allowed?(_person, message: nil) = true
    def public_intake = nil
    def public_intake_soul = nil
    def intake?(_message) = false
    def app_owners = nil
    def role_answered?(_person) = true
    def app_owner_thread?(_message, _person = nil) = false
    def app_owner_user?(_user, app_slug:, soul:) = false
    def audience_for(message, person = message.person) = AgentPerson.audience_for(person)
    def sql_guard = ->(_table) { "TRUE" }
  end

  def self.included(base)
    return unless base.respond_to?(:setup)

    base.setup { AgentMessages::Answerers.current = UnguardedAnswerers.new }
    base.teardown { AgentMessages::Answerers.reset! }
  end

  GUILD = "900000000000000001".freeze
  DESK = "900000000000000002".freeze
  QUIET = "900000000000000003".freeze
  # A channel with no entry at all: in scope because its guild is listed.
  LOUNGE = "900000000000000004".freeze
  # A muted (`ignore: true`) channel, and a thread under DESK.
  MUTED = "900000000000000005".freeze
  DESK_THREAD = "900000000000000006".freeze
  OTHER_GUILD = "900000000000000007".freeze
  AVI_ROLE = "900000000000000010".freeze
  RAY_ROLE = "900000000000000011".freeze
  AVI_BOT = "900000000000000020".freeze
  SHARED_BOT = "900000000000000099".freeze

  # One listed guild. DESK carries a `default_soul` override when one is given,
  # MUTED is ignored, and every other channel (QUIET, LOUNGE, threads) has no
  # entry at all.
  def agent_routes(default_soul: nil)
    AgentMessages::Routes.new(
      "discord" => {
        "bot_user_id" => SHARED_BOT,
        "guilds" => {
          GUILD => {
            "name" => "McRitchie",
            "channels" => { DESK => { "name" => "agent-desk", "default_soul" => default_soul.to_s },
                            MUTED => { "name" => "random", "ignore" => true } },
            "souls" => { "avi" => { "roles" => [ AVI_ROLE ], "users" => [ AVI_BOT ] },
                         "alex" => { "roles" => [ RAY_ROLE ], "users" => [] } }
          }
        }
      }
    )
  end

  # A Discord message object as GET /channels/{id}/messages returns it. Pass
  # `guild:` for the gateway's MESSAGE_CREATE shape, which carries guild_id.
  def discord_raw(id, content:, channel: DESK, author: "500", bot: false, roles: [], users: [], reply_to: nil,
                  at: Time.current, guild: nil)
    raw = {
      "id" => id.to_s, "type" => reply_to ? 19 : 0, "channel_id" => channel, "content" => content,
      "author" => { "id" => author, "username" => "alex", "global_name" => "Alex", "bot" => bot },
      "mentions" => users.map { |u| { "id" => u } }, "mention_roles" => roles,
      "timestamp" => at.iso8601
    }
    raw["message_reference"] = { "message_id" => reply_to.to_s } if reply_to
    raw["guild_id"] = guild if guild
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
