module DiscordDirectory
  # Can the bot view a channel and send to it? Discord's own permission algorithm
  # (https://discord.com/developers/docs/topics/permissions#permission-overwrites),
  # PURE: the guild's roles, the bot's role ids and user id, and the channel's
  # permission_overwrites in; a boolean out.
  #
  #   base   = @everyone's permissions | each of the bot's roles'   (ADMINISTRATOR → all)
  #   then   @everyone's overwrite, the bot's roles' overwrites (denies, then allows),
  #          and the bot's own member overwrite, each `perms & ~deny | allow`.
  #
  # A thread has no overwrites of its own: it takes its parent channel's, and
  # needs SEND_MESSAGES_IN_THREADS rather than SEND_MESSAGES.
  class Permissions
    ADMINISTRATOR = 1 << 3
    VIEW_CHANNEL = 1 << 10
    SEND_MESSAGES = 1 << 11
    SEND_MESSAGES_IN_THREADS = 1 << 38
    ALL = (1 << 53) - 1

    def initialize(guild_id:, roles:, member_role_ids:, user_id:)
      @guild_id = guild_id.to_s
      @roles = Array(roles).to_h { |role| [ role["id"].to_s, role["permissions"].to_i ] }
      @member_role_ids = Array(member_role_ids).map(&:to_s)
      @user_id = user_id.to_s
    end

    def base
      @base ||= begin
        perms = @roles.fetch(@guild_id, 0) # the @everyone role's id is the guild's
        @member_role_ids.each { |id| perms |= @roles.fetch(id, 0) }
        (perms & ADMINISTRATOR).zero? ? perms : ALL
      end
    end

    def for_channel(overwrites)
      return ALL if base == ALL

      overwrites = Array(overwrites)
      perms = apply(base, overwrites.select { |o| o["id"].to_s == @guild_id })
      perms = apply(perms, overwrites.select { |o| role_overwrite?(o) && @member_role_ids.include?(o["id"].to_s) })
      apply(perms, overwrites.select { |o| !role_overwrite?(o) && o["id"].to_s == @user_id })
    end

    def can_post?(overwrites, thread: false)
      perms = for_channel(overwrites)
      send = thread ? SEND_MESSAGES_IN_THREADS : SEND_MESSAGES
      (perms & VIEW_CHANNEL) == VIEW_CHANNEL && (perms & send) == send
    end

    private

    # Overwrites of one level fold together: every deny is applied, then every allow.
    def apply(perms, overwrites)
      allow = overwrites.reduce(0) { |acc, o| acc | o["allow"].to_i }
      deny = overwrites.reduce(0) { |acc, o| acc | o["deny"].to_i }
      (perms & ~deny) | allow
    end

    # type 0 is a role, 1 a member; an absent type with the guild's id is @everyone.
    def role_overwrite?(overwrite) = overwrite["type"].to_i.zero?
  end
end
