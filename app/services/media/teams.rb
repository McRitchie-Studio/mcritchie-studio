module Media
  # Microsoft Teams: one bot (an Azure Bot on the Bot Framework) posts as every
  # soul. Teams lets a bot set no per-message name or avatar, so each message is
  # an Adaptive Card headed with the soul's name and portrait (Media::Teams::Card).
  # Messages arrive at POST /webhooks/teams/messages
  # (Webhooks::TeamsMessagesController, JWT-verified by AgentMessages::TeamsAuth
  # → TeamsIngestJob → AgentMessages::TeamsIngest); there is no gateway
  # (docs/agents/system/agent-message-loop.md, "Teams").
  #
  # DISABLED until credentials exist: without TEAMS_BOT_APP_ID and
  # TEAMS_BOT_APP_PASSWORD a reply is `skipped` and recorded, nothing posts, and
  # :post is not a capability, so Media.home walks past Teams to its fallback.
  # config/agent_media.yml keeps `teams.enabled: false` until Steffon's
  # teams-app-kit card installs the bot.
  #
  # REPLY, ONCE, WITHOUT A NONCE, as Slack: the Bot Connector has no
  # idempotency key, so Media::OnceDelivery locks the row, records
  # `reply_sending`, and only then sends; NotPosted is retried, Refused and
  # Ambiguous never are (Media::Teams::Client sorts every outcome). The reply
  # goes to the inbound activity (POST …/activities/{activityId}), in its
  # channel thread (the ;messageid= conversation id). The noise caps
  # (Media::Teams::Limits) and the outbound ledger (SlackPost, medium "teams")
  # are Slack's.
  #
  # POSTS (Media.post): a channel's `id` in agent_media.yml teams.channels is
  # the channel's conversation id; a post needs that channel's conversation
  # reference (TeamsConversation, stored when the bot was added). Without
  # thread_ts it starts a new thread (POST /v3/conversations); with one it
  # posts in that thread.
  #
  # TYPING: Teams has a typing activity, but the capability stays off for now
  # (AgentMessage::TYPING_CHANNELS leaves teams out), as Slack's.
  class Teams < Adapter
    # Every Teams failure. Each carries a `code`.
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
    # Over a noise cap: never sent, never retried (the ledger row says why).
    class Suppressed < Error; end

    include OnceDelivery

    def initialize(client: nil, config: nil)
      super()
      @client = client
      @config = config
    end

    def key = "teams"

    def capabilities = configured? ? %i[reply post] : %i[reply]

    def inbound_mode = :webhook
    def configured? = client.configured?
    def actor = "teams-bot"

    def client = @client ||= Client.new

    def config = @config || Media::Config.current

    def limits = @limits ||= Limits.current(config: config)

    # No deep link yet: Teams' message links need the team's group id and the
    # tenant, which card 2's setup will settle.
    def message_url(_message, _message_id = nil) = nil

    # The thread a reply goes in: the conversation's root message id. Read from
    # the row's envelope (thread_root, else the activity's own id: a root post),
    # never parsed out of thread_key, whose channel part is full of colons
    # (19:…@thread.tacv2); the key's tail is only the last resort.
    def self.thread_root(message)
      env = message.envelope || {}
      env["thread_root"].presence || env["activity_id"].presence ||
        message.thread_key.to_s.delete_prefix("teams:#{message.channel_ref}:").presence
    end

    # How a soul appears on Teams: its display name (Media.display_name) and the
    # portrait Slack uses (agent_media.yml souls.<soul>.icon, else the PNG under
    # public/slack-icons/ named after config/souls.yml's avatar).
    def identity_for(soul)
      { name: Media.display_name(soul), icon_url: Media::Slack.new(config: config).icon_url(soul) }.compact
    end

    def deliver_reply(message)
      deliver_once(message) do
        env = message.envelope || {}
        service_url, conversation, activity_id = env.values_at("service_url", "conversation_id", "activity_id")
        unless service_url.present? && conversation.present? && activity_id.present?
          raise Refused.new("message #{message.id} carries no Teams conversation reference", code: "no_reference")
        end

        who = identity_for(message.soul_slug)
        text = message.response_text.to_s.presence || "(no answer text)"
        activity = Card.activity(text: text, name: who[:name], icon_url: who[:icon_url]).merge(
          from: client.bot_account, conversation: { id: conversation }, replyToId: activity_id,
          recipient: env["from_id"].present? ? { id: env["from_id"] } : nil
        ).compact
        client.reply(service_url, conversation, activity_id, activity)["id"]
      end
    end

    # A standalone post to a home's channel (its conversation id). Answers the
    # LAST card's { "ok", "ts" (the activity id), "channel" }. Errors are raised
    # for the caller (NotPosted, Refused, Ambiguous, Suppressed: every one a
    # Media::Error). Every card writes a ledger row and is checked against the
    # caps first; `key:` makes it exactly once, as Media::Slack#post.
    #
    # `text:` is one card, clipped; otherwise `content`/`embeds` are
    # Discord-shaped and chunked by Card.messages. A post with no thread_ts
    # opens a new thread with its first card and puts the rest in it.
    def post(home, content: nil, embeds: nil, soul: nil, thread_ts: nil, text: nil, kind: "post", key: nil,
             release_slug: nil, limits: nil, **)
      raise ArgumentError, "#{home.label} has no channel in config/agent_media.yml" unless home.channel? && home.channel_id

      channel = home.channel_id
      who = soul ? identity_for(soul) : {}
      bodies = if text.nil?
                 Card.messages(content: content, embeds: embeds, name: who[:name], icon_url: who[:icon_url])
               else
                 [ Card.activity(text: text.to_s, name: who[:name], icon_url: who[:icon_url]) ]
               end
      thread = thread_ts
      bodies.each_with_index.reduce(nil) do |_, (body, i)|
        row_key = key && (i.zero? ? key : "#{key}:#{i}")
        posted = ledgered(channel, soul: soul, thread_ts: thread, kind: kind, key: row_key, release_slug: release_slug,
                                   limits: limits) { send_post(channel, body, thread) }
        thread ||= posted["ts"]
        posted
      end
    end

    private

    def send_post(channel, body, thread)
      ref = TeamsConversation.installed.find_by(conversation_id: channel)
      unless ref
        raise Refused.new("no conversation reference for #{channel[0, 60]} (the bot was never added there, or was removed)",
                          code: "no_reference")
      end

      body = body.merge(from: client.bot_account)
      if thread.present?
        answer = client.send_to(ref.service_url, "#{channel};messageid=#{thread}", body)
        { "ok" => true, "ts" => answer["id"].to_s, "channel" => channel }
      else
        answer = client.create_thread(ref.service_url, channel, body, tenant_id: ref.tenant_id)
        { "ok" => true, "ts" => answer["activityId"].to_s.presence || answer["id"].to_s.split("messageid=").last.to_s,
          "channel" => channel, "conversation_id" => answer["id"].to_s }
      end
    end

    # Media::OnceDelivery's hooks.
    def reply_thread(message) = self.class.thread_root(message)

    def unconfigured_reason = "#{Client::APP_ID_ENV} / #{Client::PASSWORD_ENV} are unset"
  end
end
