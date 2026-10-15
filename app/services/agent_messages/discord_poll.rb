module AgentMessages
  # The BACKSTOP read. The Gateway listener (AgentMessages::DiscordGateway)
  # ingests messages as they are posted; this pass catches whatever it missed (a
  # reconnect gap, a dyno restart, a stood-down leader). Every 10 minutes it
  # enumerates each listed guild's text channels and active threads, reads each
  # one's messages since its cursor, stores the addressed ones once, and
  # advances the cursor. The unique index dedupes it against the gateway.
  #
  # FIRST READ OF A CHANNEL. With no cursor yet there is nothing to read "after",
  # so the poll takes the latest page and stores only messages younger than
  # BOOTSTRAP_WINDOW. That keeps a channel's old history out of the agents'
  # queue while still catching what was posted just before the first poll.
  #
  # A failure on one channel is recorded on its cursor (last_error) and the pass
  # moves on; a rate limit stops the pass, and the next run resumes.
  class DiscordPoll
    BOOTSTRAP_WINDOW = 1.hour
    # Pages per channel per pass: 5 x 100 messages per pass is far beyond what a
    # human channel produces, and it bounds one run if something floods it.
    MAX_PAGES = 5
    # Channel types that hold messages directly: GUILD_TEXT, GUILD_ANNOUNCEMENT.
    # A forum (15) or media (16) channel holds none; its posts are threads.
    TEXT_TYPES = [ 0, 5 ].freeze

    Target = Struct.new(:guild_id, :channel_id, :parent_id, keyword_init: true)
    Summary = Struct.new(:channels, :stored, :skipped, :errors, keyword_init: true)

    def initialize(routes: Routes.load, bot: nil, now: Time.current)
      @routes = routes
      @bot = bot
      @now = now
      @ingest = DiscordIngest.new(routes: routes)
    end

    def call
      summary = Summary.new(channels: 0, stored: 0, skipped: 0, errors: [])
      targets(summary).each do |target|
        summary.channels += 1
        poll_channel(target, summary)
      rescue DiscordBot::RateLimited => e
        summary.errors << "#{target.channel_id}: #{e.message}"
        break
      rescue DiscordBot::Error => e
        AgentMessageCursor.for("discord", target.channel_id).update!(last_error: e.message, polled_at: @now)
        summary.errors << "#{target.channel_id}: #{e.message}"
      end
      summary
    rescue DiscordBot::RateLimited => e
      summary.errors << e.message
      summary
    end

    private

    def bot = (@bot ||= DiscordBot.new)

    # Every text channel and active thread of every listed guild, less the muted
    # ones. A guild whose listing fails is skipped this pass; a rate limit on a
    # listing stops the whole pass (raised to #call).
    def targets(summary)
      @routes.guild_ids.flat_map do |guild_id|
        channels = bot.guild_channels(guild_id).select { |c| TEXT_TYPES.include?(c["type"].to_i) }
                      .map { |c| Target.new(guild_id: guild_id, channel_id: c["id"].to_s, parent_id: nil) }
        threads = bot.active_threads(guild_id)
                     .map { |t| Target.new(guild_id: guild_id, channel_id: t["id"].to_s, parent_id: t["parent_id"].to_s.presence) }
        (channels + threads).reject { |t| @routes.ignored?(t.guild_id, t.channel_id, parent_id: t.parent_id) }
      rescue DiscordBot::RateLimited
        raise
      rescue DiscordBot::Error => e
        summary.errors << "guild #{guild_id}: #{e.message}"
        []
      end
    end

    def poll_channel(target, summary)
      cursor = AgentMessageCursor.for("discord", target.channel_id)
      after = cursor.cursor
      MAX_PAGES.times do
        page = bot.messages_after(target.channel_id, after: after)
        bootstrap = after.blank?
        AgentMessage.transaction do
          page.each do |raw|
            if bootstrap && too_old?(raw)
              summary.skipped += 1
              next
            end
            stored = @ingest.call(raw, guild_id: target.guild_id, parent_id: target.parent_id, source: "discord-poll")
            stored&.previously_new_record? ? summary.stored += 1 : summary.skipped += 1
          end
          after = page.last["id"].to_s if page.any?
          cursor.update!(cursor: after, polled_at: @now, last_error: nil)
        end
        break if bootstrap || page.size < DiscordBot::PAGE_LIMIT
      end
    end

    def too_old?(raw)
      sent = Time.zone.parse(raw["timestamp"].to_s)
      sent.nil? || sent < @now - BOOTSTRAP_WINDOW
    rescue ArgumentError
      true
    end
  end
end
