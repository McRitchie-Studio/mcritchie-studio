require "test_helper"

# [unit] DiscordDirectory::Permissions — Discord's overwrite algorithm: base from
# @everyone and the bot's roles, ADMINISTRATOR is everything, then @everyone's,
# the roles' and the member's overwrites in that order.
class DiscordDirectory::PermissionsTest < ActiveSupport::TestCase
  P = DiscordDirectory::Permissions
  GUILD = "1"
  ROLE = "2"
  USER = "3"

  def perms(everyone:, role: 0)
    P.new(guild_id: GUILD, roles: [ { "id" => GUILD, "permissions" => everyone.to_s }, { "id" => ROLE, "permissions" => role.to_s } ],
          member_role_ids: [ ROLE ], user_id: USER)
  end

  def ow(id, type, allow: 0, deny: 0) = { "id" => id, "type" => type, "allow" => allow.to_s, "deny" => deny.to_s }

  test "[unit] base permissions, and a role overwrite allow beats an @everyone deny" do
    p = perms(everyone: P::VIEW_CHANNEL | P::SEND_MESSAGES)
    assert p.can_post?([])
    assert_not p.can_post?([ ow(GUILD, 0, deny: P::SEND_MESSAGES) ])
    assert p.can_post?([ ow(GUILD, 0, deny: P::SEND_MESSAGES), ow(ROLE, 0, allow: P::SEND_MESSAGES) ])
  end

  test "[unit] the member overwrite is applied last" do
    p = perms(everyone: P::VIEW_CHANNEL | P::SEND_MESSAGES)
    assert_not p.can_post?([ ow(ROLE, 0, allow: P::SEND_MESSAGES), ow(USER, 1, deny: P::SEND_MESSAGES) ])
  end

  test "[unit] ADMINISTRATOR ignores every overwrite, and a thread needs SEND_MESSAGES_IN_THREADS" do
    assert perms(everyone: 0, role: P::ADMINISTRATOR).can_post?([ ow(GUILD, 0, deny: P::VIEW_CHANNEL) ])

    p = perms(everyone: P::VIEW_CHANNEL | P::SEND_MESSAGES)
    assert_not p.can_post?([], thread: true)
    assert perms(everyone: P::VIEW_CHANNEL | P::SEND_MESSAGES_IN_THREADS).can_post?([], thread: true)
  end
end
