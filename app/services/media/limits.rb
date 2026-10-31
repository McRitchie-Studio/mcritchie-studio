module Media
  # The noise caps on what the agents say on a chat medium (config/agent_media.yml
  # `limits:`; docs/agents/system/agent-message-loop.md, "Noise rules"), shared
  # by every medium that posts as a soul: Slack (Media::Slack::Limits) and
  # Microsoft Teams (Media::Teams::Limits). Enforced at each medium's one
  # outbound seam (its #post and #deliver_reply ask #refusal before every send,
  # through Media::OnceDelivery), so no prompt can talk past them. Counted from
  # the outbound ledger (SlackPost, table slack_posts, its `medium` column
  # scoping each medium's rows): the conductor posts from a `heroku run` dyno and
  # replies post from a job dyno.
  #
  #   per_soul_per_channel_per_hour   (default 6) posts one soul made in one
  #       channel in the last hour. A release post is exempt but counted; so is
  #       an answer to a message Alex McRitchie wrote himself while
  #       owner_replies_count_only is true (his own question is never noise).
  #   replies_per_thread_without_owner (default 4) agent posts in one thread
  #       since Alex McRitchie last wrote in it. Nothing is exempt.
  #
  # The caps are one `limits:` block for every medium: a soul's six an hour are
  # per channel, and a channel is on one medium, so Slack and Teams never share
  # a count. A soul-less post (a report, an alert through a home) is not an
  # agent speaking: it is recorded, never capped.
  class Limits
    DEFAULTS = {
      "per_soul_per_channel_per_hour" => 6,
      "replies_per_thread_without_owner" => 4,
      "owner_replies_count_only" => true
    }.freeze
    WINDOW = 1.hour

    attr_reader :per_hour, :per_thread, :owner_user_id, :medium

    def initialize(config = {}, owner_user_id: nil, medium: "slack")
      settings = DEFAULTS.merge((config || {}).to_h.stringify_keys.slice(*DEFAULTS.keys).compact)
      @per_hour = settings["per_soul_per_channel_per_hour"].to_i
      @per_thread = settings["replies_per_thread_without_owner"].to_i
      @owner_count_only = settings["owner_replies_count_only"] == true
      @owner_user_id = owner_user_id.to_s.presence
      @medium = medium.to_s
    end

    # nil when the post may go, else why it may not (for the ledger row, the
    # message timeline and the log).
    def refusal(channel_id:, soul:, kind:, thread_ts: nil, owner_reply: false, now: Time.current)
      return nil if soul.blank?

      if thread_ts.present? && per_thread.positive?
        count = thread_count(channel_id, thread_ts)
        if count >= per_thread
          return "thread cap: #{count} agent posts in this thread since Alex McRitchie last wrote in it " \
                 "(limit #{per_thread}, config/agent_media.yml limits.replies_per_thread_without_owner)"
        end
      end
      return nil if kind.to_s == "release" || (owner_reply && @owner_count_only)
      return nil unless per_hour.positive?

      count = hourly_count(channel_id, soul, now)
      return nil if count < per_hour

      "hourly cap: #{soul} posted #{count} times in this channel in the last hour " \
        "(limit #{per_hour}, config/agent_media.yml limits.per_soul_per_channel_per_hour)"
    end

    def hourly_count(channel_id, soul, now = Time.current)
      ledger.posted.where(channel_id: channel_id.to_s, soul_slug: soul.to_s)
            .where(created_at: (now - WINDOW)..now).count
    end

    # Agent posts in the thread after Alex McRitchie's last message there (all
    # of them when he has not written in it).
    def thread_count(channel_id, thread_ts)
      scope = ledger.posted.by_agent.where(channel_id: channel_id.to_s, thread_ts: thread_ts.to_s)
      since = owner_last_wrote(channel_id, thread_ts)
      scope = scope.where("slack_posts.created_at > ?", since) if since
      scope.count
    end

    # Both media key a thread "<medium>:<channel>:<root id>" (SlackIngest,
    # TeamsIngest), and the owner's author_ref is his id on that medium.
    def owner_last_wrote(channel_id, thread_ts)
      return nil if owner_user_id.nil?

      AgentMessage.where(channel: medium, channel_ref: channel_id.to_s, author_ref: owner_user_id,
                         thread_key: "#{medium}:#{channel_id}:#{thread_ts}").maximum(:created_at)
    end

    private

    def ledger = SlackPost.where(medium: medium)
  end
end
