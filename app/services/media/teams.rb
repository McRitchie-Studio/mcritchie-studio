module Media
  # Microsoft Teams: REGISTERED AND DISABLED. The hub speaks no Teams yet; this
  # stub holds the medium's place in the registry so the seam is shaped for it
  # (.agents/epics/omnichannel-media.md). It answers only what the registry and
  # Media.home must ask without raising (key, capabilities, enabled?); every
  # other method raises NotImplementedError, so nothing can quietly "send" on
  # Teams. config/agent_media.yml keeps `teams.enabled: false`, and Media.home
  # walks past it (no :post capability) to its fallback.
  #
  # The sketch for the card that fills it in (verify against Microsoft's docs
  # then; this is from memory):
  #
  # INBOUND (inbound_mode :webhook). An Azure Bot resource posts Bot Framework
  # Activities to POST /webhooks/teams/messages. Every request carries
  # `Authorization: Bearer <JWT>`, signed by the Bot Connector: fetch the OpenID
  # metadata (https://login.botframework.com/v1/.well-known/openidconfiguration),
  # cache its JWKS, and check the signature, `iss` (https://api.botframework.com),
  # `aud` (our Microsoft App id) and `serviceUrl` claim matching the activity's.
  # A `message` activity becomes an AgentMessage (channel "teams", external_id
  # the activity id, channel_ref the conversation id, thread_key the
  # conversation id plus replyToId's root), routed by @mention of the bot
  # (entities[type=mention]) or the channel's default soul.
  #
  # REPLIES (deliver_reply). POST {serviceUrl}/v3/conversations/{conversationId}/
  # activities/{replyToId} with a bot token from the client-credentials grant
  # (login.microsoftonline.com, scope https://api.botframework.com/.default).
  # The reply threads under the message by replyToId. No idempotency key: lock
  # the row and retry only a provable non-post, as for Slack.
  #
  # TYPING (typing). Native: POST an activity of `type: "typing"` to the same
  # conversation; it shows for a few seconds, so the dispatcher's pulse cadence
  # fits as it is.
  #
  # POSTS (post). A proactive message to a channel needs the conversation
  # reference saved at install (conversationUpdate), then the same Connector
  # POST without replyToId.
  class Teams < Adapter
    def key = "teams"
    def capabilities = []
    def configured? = false
    def enabled? = false

    def inbound_mode = not_yet(:inbound_mode)
    def deliver_reply(_message) = not_yet(:deliver_reply)
    def typing(_message, phase: nil) = not_yet(:typing)
    def post(*, **) = not_yet(:post)
    def message_url(*) = not_yet(:message_url)
    def setup_kit = not_yet(:setup_kit)
    def actor = not_yet(:actor)

    private

    def not_yet(method)
      raise NotImplementedError, "Media::Teams##{method}: Microsoft Teams is registered but not built (.agents/epics/omnichannel-media.md)"
    end
  end
end
