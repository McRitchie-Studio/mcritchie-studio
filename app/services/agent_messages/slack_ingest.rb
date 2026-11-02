module AgentMessages
  # Stores ONE Slack Events API event as an AgentMessage, once
  # (docs/agents/system/agent-message-loop.md, "Slack"). Called by SlackIngestJob
  # with the event hash and the payload's team_id.
  #
  # THE ROW. channel "slack", external_id "<channel id>:<ts>" (a ts is unique
  # only within its channel), guild_id the team id, channel_ref the channel id,
  # thread_key "slack:<channel>:<thread_ts || ts>" (a Slack thread is one
  # conversation, keyed by its root), and envelope.channel_type ("im" for a DM:
  # MemoryBundle#private_channel?).
  #
  # ONCE. The unique index on (channel, external_id) is the guard: Slack retries
  # an event it got no quick 200 for, and a message that mentions the app comes
  # twice (message.channels and app_mention, the same ts). The loser of a race
  # gets the winner's row back, as in DiscordIngest.
  #
  # WHAT IS NEVER STORED: an event from another workspace; anything a bot wrote
  # (bot_id, subtype bot_message, or the app's own bot user: our customized posts
  # come back as events, as do the Steffon Admin app's); edits, deletes, joins
  # and every other subtype; a muted channel; an unaddressed message.
  #
  # ROUTING (AgentMessages::SlackRoutes): the souls NAMED at the start of the
  # text (one, or a list: "Avi and Mason, …"), or EVERYONE ("Everyone, …":
  # every soul served and cleared in the channel), else the soul of the thread
  # it replies in, else the app's mention soul for an @-mention or a DM, else
  # the channel's default soul. A reply in a thread the mailbox holds whose
  # thread has no soul is kept `unrouted`, as on Discord.
  #
  # FAN-OUT. A message for several souls is stored as one row per soul, in one
  # transaction, all in the message's thread: the first-named soul's row keeps
  # "<channel>:<ts>" (so dedupe and every older row are unchanged), each
  # other's is "<channel>:<soul>:<ts>" (#sibling_id), and every row carries
  # envelope.fan = the primary's id, which lets them be claimed side by side
  # (AgentMessage::FAN_KEY). #call returns the primary. A later, unnamed reply
  # in that thread goes to the first-named soul that is not held (#thread_row):
  # Slack threads are flat, so an event never says which reply it answers.
  #
  # CLEARANCE (SlackRoutes#cleared?), per soul, so a fan-out holds only the
  # uncleared souls' rows: a channel may name the souls cleared to
  # answer in it (`souls:` plus the block's core_souls) or admit all (`open:
  # true`). A message routed, by any rule, to a soul not cleared there is stored
  # `held` with the reason on its `held` event, and never answered unless an
  # admin releases it. A channel with no clearance config admits every soul.
  # A soul only RECOGNIZED by name (slack.recognized: no dispatcher serves it on
  # Slack) is routed and held the same way, reason "soul cannot answer yet", so
  # "Carl, …" never falls through to a channel default another soul answers.
  #
  # THE OWNER-ONLY GUARD and THE PERSON are DiscordIngest's: the Slack user id is
  # the identity (AgentPerson.resolve!, platform "slack"); a routed message from
  # a role config/agent_answerers.yml does not answer is stored `held`. Alex
  # McRitchie's user id is linked to the owner (AgentPerson.seed_owner!).
  #
  # FILES (AgentMessages::SlackFiles). An image or PDF on a message at least one
  # soul will answer is fetched and attached to every row of it. A held sender's
  # file is never fetched. A file that cannot be read never loses the message:
  # envelope.files_skipped names it and why, and the prompt says so. One mention
  # comes as two events, and only one may carry the files, so a repeat that brings
  # files to rows holding none attaches them (#attach_late_files).
  class SlackIngest
    CHANNEL = "slack".freeze
    # Subtypes that are still a person's new message.
    MESSAGE_SUBTYPES = [ nil, "", "file_share", "thread_broadcast" ].freeze
    EVENT_TYPES = %w[message app_mention].freeze
    RECEIVED_ACTOR = "slack-events".freeze

    # Routing, clearance, the owner-only guard and fan-out are shared with
    # Teams (AgentMessages::ChatIngest).
    include ChatIngest

    def initialize(routes: SlackRoutes.current, answerers: Answerers.current, client: nil, logger: Rails.logger,
                   files: SlackFiles.new)
      @routes = routes
      @answerers = answerers
      @client = client
      @files = files
      @logger = logger
    end

    # The stored row, the existing row on a repeat, or nil when the event is
    # not kept.
    def call(event, team_id:, event_id: nil)
      event = event.to_h.deep_stringify_keys
      return nil unless inbound?(event)
      return note_other_team(team_id) unless @routes.team?(team_id)
      return nil if @routes.ignored?(event["channel"])

      external_id = "#{event['channel']}:#{event['ts']}"
      existing = AgentMessage.find_by(channel: CHANNEL, external_id: external_id)
      if existing
        attach_late_files(existing, event, external_id)
        return existing
      end

      store(event, external_id, { team_id: team_id.to_s, event_id: event_id })
    rescue ActiveRecord::RecordNotUnique
      lost_race(event, external_id)
    rescue ActiveRecord::RecordInvalid => e
      raise unless e.record.is_a?(AgentMessage) && e.record.errors.of_kind?(:external_id, :taken)

      lost_race(event, external_id)
    end

    private

    # The winner's row. A twin with no files may have won while this event fetched its own.
    def lost_race(event, external_id)
      AgentMessage.find_by(channel: CHANNEL, external_id: external_id)&.tap { |row| attach_late_files(row, event, external_id) }
    end

    # ChatIngest's hook: why the message is to the app itself, or nil.
    def mention_reason(event, text)
      return nil unless @routes.mentions_bot?(text) || event["type"] == "app_mention" || im?(event)

      im?(event) ? "direct message" : "app mention"
    end

    def inbound?(event)
      return false unless EVENT_TYPES.include?(event["type"])
      return false unless MESSAGE_SUBTYPES.include?(event["subtype"])
      return false if event["bot_id"].present? || event["bot_profile"].present?
      return false if event["user"].blank? || event["channel"].blank? || event["ts"].blank?
      return false if @routes.bot_user_id.present? && event["user"] == @routes.bot_user_id

      true
    end

    # FAN-OUT KEYS. The primary (first-named) row keeps "<channel>:<ts>", so a
    # single-soul message, every row stored before fan-out, and the dedupe lookup
    # in #call are unchanged; each further soul's row is "<channel>:<soul>:<ts>".
    # The ts stays the LAST segment, which Media::Slack#message_url reads. All of
    # a message's rows are written in one transaction, so a retry or the
    # app_mention twin finds the primary and gets every row or none.
    def sibling_id(event, soul) = "#{event['channel']}:#{soul}:#{event['ts']}"

    # ChatIngest's hook: Slack's own columns on each row.
    def row_attributes(event, ctx)
      { guild_id: ctx[:team_id], channel_ref: event["channel"].to_s,
        mentions: { "users" => mentioned_users(event["text"]) }, sent_at: Time.zone.at(event["ts"].to_f),
        envelope: { "channel_type" => channel_type(event), "event_id" => ctx[:event_id].presence,
                    "thread_ts" => event["thread_ts"].presence, AgentMessage::FAN_KEY => ctx[:fan],
                    "files_skipped" => ctx[:files]&.skipped.presence }.compact }
    end

    # The message + app_mention pair: the twin that landed first may have carried
    # no files. Every row of the message gets them, under the same guard as a
    # first store. A row with files or a skip on it has had its turn.
    def attach_late_files(primary, event, external_id)
      return if Array(event["files"]).empty? || primary.attachments.attached? || primary.envelope["files_skipped"].present?

      files = files_for(event, routes_for(event), primary.author_name)
      return unless files

      rows = AgentMessage.where(channel: CHANNEL)
      rows.where(external_id: external_id).or(rows.where("envelope->>? = ?", AgentMessage::FAN_KEY, external_id)).find_each do |row|
        row.attachments.attach(files.blobs) if files.blobs.any?
        row.update!(envelope: row.envelope.merge("files_skipped" => files.skipped)) if files.skipped.any?
      end
    end

    # ChatIngest's hook: the event's files, stored, when a soul will answer it.
    def files_for(event, results, name)
      return nil if Array(event["files"]).empty?

      person = AgentPerson.resolve!(platform: CHANNEL, external_id: event["user"].to_s, display_name: name)
      return nil unless results.any? { |result| answered?(event, result, person) }

      @files.call(event, team_id: @routes.team_id)
    end

    def display_name(event) = author_name(event["user"].to_s)

    def thread_key(event) = "slack:#{event['channel']}:#{event['thread_ts'].presence || event['ts']}"

    # app_mention events carry no channel_type; a DM's channel id starts with D.
    def channel_type(event) = event["channel_type"].presence || (event["channel"].to_s.start_with?("D") ? "im" : "channel")

    def im?(event) = channel_type(event) == "im"

    def mentioned_users(text) = text.to_s.scan(/<@([UW][A-Z0-9]+)(?:\|[^>]*)?>/).flatten.uniq

    # The sender's Slack display name (users.info, best effort), else their id.
    def author_name(user_id)
      client = @client || Media::Slack::Client.new
      (client.configured? && client.user_name(user_id)).presence || "slack #{user_id}"
    rescue StandardError
      "slack #{user_id}"
    end

    def note_other_team(team_id)
      @logger.info("[agent-messages] ignoring Slack team #{team_id.to_s[0, 20]}: not config/agent_routes.yml slack.team_id")
      nil
    end
  end
end
