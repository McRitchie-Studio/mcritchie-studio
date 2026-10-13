module AgentMessages
  # One pass over every allow-listed Discord channel: read what is new since the
  # channel's cursor, store each message once, advance the cursor.
  #
  # FIRST READ OF A CHANNEL. With no cursor yet there is nothing to read "after",
  # so the poll takes the latest page and stores only messages younger than
  # BOOTSTRAP_WINDOW. That keeps a channel's old history out of the agents'
  # queue while still catching what Alex posted just before the first poll.
  #
  # A failure on one channel is recorded on its cursor (last_error) and the pass
  # moves on; a rate limit stops the pass, and the next minute's run resumes.
  class DiscordPoll
    BOOTSTRAP_WINDOW = 1.hour
    # Pages per channel per pass: 5 x 100 messages a minute is far beyond what a
    # human channel produces, and it bounds one run if something floods it.
    MAX_PAGES = 5

    Summary = Struct.new(:channels, :stored, :skipped, :errors, keyword_init: true)

    def initialize(routes: Routes.load, bot: nil, now: Time.current)
      @routes = routes
      @bot = bot
      @now = now
      @ingest = DiscordIngest.new(routes: routes)
    end

    def call
      summary = Summary.new(channels: 0, stored: 0, skipped: 0, errors: [])
      @routes.channels.each do |channel|
        summary.channels += 1
        poll_channel(channel, summary)
      rescue DiscordBot::RateLimited => e
        summary.errors << "#{channel.channel_id}: #{e.message}"
        break
      rescue DiscordBot::Error => e
        AgentMessageCursor.for("discord", channel.channel_id).update!(last_error: e.message, polled_at: @now)
        summary.errors << "#{channel.channel_id}: #{e.message}"
      end
      summary
    end

    private

    def bot = (@bot ||= DiscordBot.new)

    def poll_channel(channel, summary)
      cursor = AgentMessageCursor.for("discord", channel.channel_id)
      after = cursor.cursor
      MAX_PAGES.times do
        page = bot.messages_after(channel.channel_id, after: after)
        bootstrap = after.blank?
        AgentMessage.transaction do
          page.each do |raw|
            if bootstrap && too_old?(raw)
              summary.skipped += 1
              next
            end
            stored = @ingest.call(raw, guild_id: channel.guild_id)
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
