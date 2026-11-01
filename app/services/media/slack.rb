module Media
  # Slack: one app (McRitchie Agents, A0CDCN1Q9AS) posts as every soul, with the
  # soul's name and portrait on each message (chat:write.customize). Messages
  # arrive by the Events API at POST /webhooks/slack/events
  # (Webhooks::SlackEventsController → SlackIngestJob → AgentMessages::
  # SlackIngest); there is no gateway and no leader
  # (docs/agents/system/agent-message-loop.md, "Slack").
  #
  # REPLY, ONCE, WITHOUT A NONCE. chat.postMessage has no idempotency key, so a
  # reply that timed out may already be in the channel. deliver_reply therefore
  # LOCKS THE ROW, writes a `reply_sending` event, commits, and only then posts:
  #   posted       the ts is stored (reply_external_id): no job posts again.
  #   NotPosted    provably not posted, worth retrying (a 429, ratelimited):
  #                `reply_not_posted` is recorded and the error raised, so
  #                AgentMessageReplyJob's retry_on Media::Error tries again.
  #   Refused      provably not posted, a retry would be refused too
  #                (channel_not_found, not_in_channel): failed, not retried.
  #   Ambiguous    it may have posted (a read timeout, a 5xx): failed, NOT
  #                retried; the timeline says to look in the channel.
  # A job that finds a `reply_sending` with no outcome after it either sees a
  # live attempt (younger than IN_FLIGHT, it leaves it alone) or a crashed one
  # (older: failed as ambiguous, never re-posted).
  #
  # TYPING: Slack has no typing indicator for a bot, so the capability is off
  # (AgentMessage::TYPING_CHANNELS leaves slack out).
  #
  # POSTS (Media.post): `content` and/or Discord-shaped `embeds`, converted by
  # Media::Slack::Format, to a channel id named in config/agent_media.yml.
  # :post is a capability only while SLACK_BOT_TOKEN is set, so Media.home walks
  # past an unconfigured Slack to its fallback (a half-set Slack never silences
  # the floor alert).
  class Slack < Adapter
    TOKEN_ENV = "SLACK_BOT_TOKEN".freeze
    SIGNING_SECRET_ENV = "SLACK_SIGNING_SECRET".freeze

    # The reply claim, the ledger and the caps are shared with Teams
    # (Media::OnceDelivery): SENDING_EVENT, NOT_POSTED_EVENT, SUPPRESSED_EVENT
    # and IN_FLIGHT are its.
    include OnceDelivery

    REPLY_LIMIT = 39_000

    # Every Slack failure. Each carries Slack's error `code`.
    class Error < Media::Error
      attr_reader :code, :retry_after

      def initialize(message = nil, code: nil, retry_after: nil)
        super(message)
        @code = code
        @retry_after = retry_after
      end
    end

    class NotPosted < Error; end
    class Refused < Error; end
    class Ambiguous < Error; end
    # Over a noise cap (Media::Slack::Limits): never sent, never retried. The
    # SlackPost row (status suppressed) carries the reason.
    class Suppressed < Error; end

    def initialize(client: nil, config: nil)
      super()
      @client = client
      @config = config
    end

    def key = "slack"

    def capabilities = configured? ? %i[reply post] : %i[reply]

    def inbound_mode = :webhook
    def configured? = client.configured?
    def actor = "slack-bot"

    def client = @client ||= Client.new

    def config = @config || Media::Config.current

    # https://<workspace>/archives/<channel>/p<ts without the dot>. The
    # workspace URL is agent_media.yml's slack.workspace_url (else slack.com,
    # which redirects a signed-in member).
    def message_url(message, message_id = message.external_id)
      ts = message_id.to_s.split(":").last.to_s
      return nil unless message.channel == key && message.channel_ref.present? && ts.match?(/\A\d+\.\d+\z/)

      base = ((config.medium(key) || {})["workspace_url"].presence || "https://slack.com").delete_suffix("/")
      "#{base}/archives/#{message.channel_ref}/p#{ts.delete('.')}"
    end

    # The thread a reply goes in: the conversation's root ts (the thread_key's
    # last segment), so a reply to a reply stays in the one thread.
    def self.thread_ts(message) = message.thread_key.to_s.split(":").last

    # How a soul appears on Slack: its display name (Media.display_name) and an
    # absolute portrait URL (agent_media.yml souls.<soul>.icon, else the PNG
    # under public/slack-icons/ named after config/souls.yml's avatar).
    def identity_for(soul)
      { username: Media.display_name(soul), icon_url: icon_url(soul) }.compact
    end

    def icon_url(soul)
      path = config.entry("souls", soul)&.dig("icon").to_s.presence || default_icon_path(soul)
      return nil if path.blank?
      return path if path.match?(%r{\Ahttps://})

      "https://#{ENV.fetch('APP_HOST', 'mcritchie.studio')}#{path.start_with?('/') ? path : "/#{path}"}"
    end

    def deliver_reply(message)
      deliver_once(message) do
        post_text(message.channel_ref, message.response_text.to_s, soul: message.soul_slug,
                                                                  thread_ts: self.class.thread_ts(message))["ts"]
      end
    end

    # A standalone post to a home's channel id. Answers the LAST message's
    # Slack JSON. Errors are raised for the caller (NotPosted, Refused,
    # Ambiguous, Suppressed: every one a Media::Error).
    #
    # `text:` is Slack mrkdwn already (one message, clipped, never converted:
    # a <@U…> mention or a <url|label> link passes through); otherwise
    # `content`/`embeds` are Discord-shaped and converted by Format.
    #
    # THE LEDGER AND THE CAPS. Every message writes a SlackPost row, and one
    # posted as a soul is first checked against the noise caps (Limits): over
    # one, the row is `suppressed` with the reason, the log says so, and
    # Suppressed is raised; nothing is sent. `kind: "release"` is exempt from
    # the hourly cap, still counted.
    #
    # ONCE, BY KEY. With `key:` the row is claimed under that idempotency key
    # BEFORE the post: a key already posted answers that post's ts with
    # "already_posted" => true and sends nothing; one suppressed, still
    # `sending` (a crashed attempt) or failed ambiguously raises again and
    # sends nothing (it may have posted: look in the channel); one Slack
    # provably refused is tried again.
    def post(home, content: nil, embeds: nil, soul: nil, thread_ts: nil, text: nil, kind: "post", key: nil,
             release_slug: nil, limits: nil, **)
      raise ArgumentError, "#{home.label} has no channel in config/agent_media.yml" unless home.channel? && home.channel_id

      bodies = text.nil? ? Format.messages(content: content, embeds: embeds) : [ { text: Format.clip(text.to_s, REPLY_LIMIT) } ]
      bodies.each_with_index.reduce(nil) do |_, (body, i)|
        row_key = key && (i.zero? ? key : "#{key}:#{i}")
        ledgered(home.channel_id, soul: soul, thread_ts: thread_ts, kind: kind, key: row_key,
                                  release_slug: release_slug, limits: limits) do
          client.post_message(body.merge(channel: home.channel_id, thread_ts: thread_ts).merge(soul ? identity_for(soul) : {}).compact)
        end
      end
    end

    def limits = @limits ||= Limits.current(config: config)

    private

    # ONE message, so a retry can never leave half an answer posted twice:
    # mrkdwn, clipped under Slack's 40,000-character truncation.
    #
    # NO LINK PREVIEWS. A reply is model-written text a sender can steer (a
    # scoped run's tool output, a proposal's result, any answer), and Slack
    # fetches every link it unfurls; so an answer never unfurls (Carl's
    # follow-up on slack-owner-terminal-scope).
    def post_text(channel, text, soul:, thread_ts:)
      body = Format.clip(Format.mrkdwn(text).presence || "(no answer text)", REPLY_LIMIT)
      client.post_message({ channel: channel, text: body, thread_ts: thread_ts, unfurl_links: false, unfurl_media: false }
                            .merge(identity_for(soul)).compact)
    end

    # Media::OnceDelivery's hooks.
    def reply_thread(message) = self.class.thread_ts(message)

    def unconfigured_reason = "#{TOKEN_ENV} is unset"

    def default_icon_path(soul)
      # The mailbox's turf_monster is config/souls.yml's turf-monster.
      avatar = (soul_avatars[soul.to_s] || soul_avatars[soul.to_s.tr("_", "-")]).to_s
      return nil if avatar.blank?

      png = "/slack-icons/#{File.basename(avatar, '.*')}.png"
      Rails.public_path.join(png.delete_prefix("/")).file? ? png : nil
    end

    def soul_avatars
      @soul_avatars ||= begin
        rows = YAML.safe_load_file(Rails.root.join("config/souls.yml"), aliases: false)&.dig("souls") || []
        rows.to_h { |row| [ row["slug"].to_s, row["avatar"].to_s ] }
      rescue StandardError
        {}
      end
    end
  end
end
