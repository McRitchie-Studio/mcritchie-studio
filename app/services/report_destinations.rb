require "digest"

# Deliver a registered report to the Discord channel Alex picked for it.
# THE CONTRACT other sessions build against: docs/agents/system/report-destinations.md.
#
#   result = ReportDestinations.deliver("daily_app_report",
#                                       content: "…", embeds: [], idempotency_key: "daily_app_report:2026-10-15")
#   result.status      # :posted | :not_configured | :disabled | :failed
#   result.message_id  # the Discord message id (posted only)
#   result.url         # a link to the message (posted only)
#
# Once per idempotency_key. A key already `posted` returns that delivery and
# posts nothing; Discord's nonce + enforce_nonce (derived from the key) folds a
# racing or retried post into the message it already made. Nothing is pinged
# (allowed_mentions parses nothing). Every call is recorded in report_deliveries.
#
# Over Discord's limits it RAISES ReportDestinations::LimitExceeded (an
# ArgumentError) before anything is posted or recorded: a report is never
# silently cut or split.
module ReportDestinations
  REGISTRY_PATH = Rails.root.join("config/report_destinations.yml")

  # Discord's per-message limits (https://discord.com/developers/docs/resources/message,
  # .../resources/message#embed-object-embed-limits). Lengths are UTF-16 units.
  CONTENT_LIMIT = 2000
  EMBEDS_LIMIT = 10
  EMBED_TOTAL_LIMIT = 6000
  EMBED_FIELD_LIMITS = { title: 256, description: 4096 }.freeze
  EMBED_FIELDS_LIMIT = 25
  FIELD_NAME_LIMIT = 256
  FIELD_VALUE_LIMIT = 1024
  FOOTER_TEXT_LIMIT = 2048
  AUTHOR_NAME_LIMIT = 256
  IDEMPOTENCY_KEY_LIMIT = 255

  LimitExceeded = Class.new(ArgumentError)

  Registration = Struct.new(:key, :label, :description, keyword_init: true)

  Result = Struct.new(:status, :message_id, :url, :reason, :delivery, keyword_init: true) do
    def posted? = status == :posted
  end

  module_function

  def registrations
    config = YAML.safe_load_file(REGISTRY_PATH, aliases: false) || {}
    (config["reports"] || {}).map do |key, entry|
      entry ||= {}
      Registration.new(key: key.to_s, label: entry["label"].to_s.presence || key.to_s.humanize,
                       description: entry["description"].to_s)
    end
  end

  def registration(report_key) = registrations.find { |r| r.key == report_key.to_s }
  def registered?(report_key) = !registration(report_key).nil?

  # Returns a Result. Raises ArgumentError for an unknown key, a blank
  # idempotency_key, an empty report, or (LimitExceeded) one over Discord's limits.
  def deliver(report_key, content:, idempotency_key:, embeds: [])
    Delivery.new(report_key, content: content, embeds: embeds, idempotency_key: idempotency_key).call
  end

  # The same, but a Discord failure RAISES AgentMessages::DiscordBot::Error after
  # it is recorded, so ReportDeliveryJob's retry can take it.
  def deliver!(report_key, content:, idempotency_key:, embeds: [])
    Delivery.new(report_key, content: content, embeds: embeds, idempotency_key: idempotency_key, raise_failure: true).call
  end

  # Discord's nonce is at most 25 characters; this one is stable per key.
  def nonce_for(idempotency_key) = "rpt#{Digest::SHA256.hexdigest(idempotency_key.to_s)[0, 22]}"

  # Raises LimitExceeded naming the first limit the report breaks.
  def check_limits!(content, embeds)
    length = ->(text) { ReleaseNotes::DiscordClient.discord_length(text) }
    over = ->(what, size, limit) { raise LimitExceeded, "#{what} is #{size} characters; Discord's limit is #{limit}" if size > limit }

    over.("content", length.(content), CONTENT_LIMIT)
    raise LimitExceeded, "#{embeds.size} embeds; Discord's limit is #{EMBEDS_LIMIT} per message" if embeds.size > EMBEDS_LIMIT

    total = 0
    embeds.each_with_index do |embed, i|
      raise ArgumentError, "embeds[#{i}] is not a Hash" unless embed.is_a?(Hash)

      embed = embed.with_indifferent_access
      EMBED_FIELD_LIMITS.each { |field, limit| over.("embeds[#{i}].#{field}", length.(embed[field]), limit) }
      over.("embeds[#{i}].footer.text", length.(embed.dig(:footer, :text)), FOOTER_TEXT_LIMIT)
      over.("embeds[#{i}].author.name", length.(embed.dig(:author, :name)), AUTHOR_NAME_LIMIT)
      fields = Array(embed[:fields])
      raise LimitExceeded, "embeds[#{i}] has #{fields.size} fields; Discord's limit is #{EMBED_FIELDS_LIMIT}" if fields.size > EMBED_FIELDS_LIMIT

      fields.each_with_index do |field, j|
        field = field.to_h.with_indifferent_access
        over.("embeds[#{i}].fields[#{j}].name", length.(field[:name]), FIELD_NAME_LIMIT)
        over.("embeds[#{i}].fields[#{j}].value", length.(field[:value]), FIELD_VALUE_LIMIT)
      end
      total += ReleaseNotes::DiscordClient.embed_length(embed)
    end
    over.("the embeds' total text", total, EMBED_TOTAL_LIMIT)
  end

  # One deliver call. Kept out of the module's surface; `deliver` is the API.
  class Delivery
    def initialize(report_key, content:, embeds:, idempotency_key:, raise_failure: false)
      @report_key = report_key.to_s
      @content = content.to_s
      @embeds = Array(embeds)
      @idempotency_key = idempotency_key.to_s
      @raise_failure = raise_failure
    end

    def call
      validate!
      receipt = find_or_create_receipt
      # The row lock is held across the post, so a racing caller with the same
      # key waits here and then sees `posted`.
      result = receipt.with_lock { receipt.posted? ? finished(receipt) : attempt(receipt) }
      # Raised only after the lock's transaction has committed the failed receipt.
      raise @failure if @raise_failure && @failure

      result
    end

    private

    def validate!
      raise ArgumentError, "unknown report key #{@report_key.inspect}: register it in config/report_destinations.yml" unless ReportDestinations.registered?(@report_key)
      raise ArgumentError, "idempotency_key is required" if @idempotency_key.blank?
      raise ArgumentError, "idempotency_key is over #{IDEMPOTENCY_KEY_LIMIT} characters" if @idempotency_key.length > IDEMPOTENCY_KEY_LIMIT
      raise ArgumentError, "a report needs content or at least one embed" if @content.blank? && @embeds.empty?

      ReportDestinations.check_limits!(@content, @embeds)
    end

    def find_or_create_receipt
      receipt = ReportDelivery.find_or_create_by!(idempotency_key: @idempotency_key) do |row|
        row.report_key = @report_key
        row.status = "pending"
      end
      if receipt.report_key != @report_key
        raise ArgumentError, "idempotency_key #{@idempotency_key.inspect} was already used for report #{receipt.report_key.inspect}"
      end

      receipt
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    def attempt(receipt)
      destination = ReportDestination.for(@report_key)
      channel = destination&.discord_channel
      return skip(receipt, :not_configured, "no channel is chosen for #{@report_key}") if channel.nil?
      return skip(receipt, :disabled, "delivery of #{@report_key} is turned off") unless destination.enabled?
      return skip(receipt, :not_configured, "#{channel.display_name} is archived or not postable") unless channel.selectable?
      return failure(receipt, channel, AgentMessages::DiscordBot::Error.new("#{AgentMessages::DiscordBot::TOKEN_ENV} is unset")) unless AgentMessages::DiscordBot.configured?

      posted = AgentMessages::DiscordBot.new.post_report(channel.external_id, content: @content, embeds: @embeds,
                                                                              nonce: ReportDestinations.nonce_for(@idempotency_key))
      receipt.update!(status: "posted", discord_channel: channel, guild_external_id: channel.guild_external_id,
                      channel_external_id: channel.external_id, message_external_id: posted["id"].to_s,
                      posted_at: Time.current, error: nil)
      finished(receipt)
    rescue AgentMessages::DiscordBot::Error => e
      failure(receipt, channel, e)
    end

    def skip(receipt, status, reason)
      receipt.update!(status: status.to_s, error: reason)
      Result.new(status: status, reason: reason, delivery: receipt)
    end

    def failure(receipt, channel, error)
      receipt.update!(status: "failed", error: error.message.to_s[0, 500], discord_channel: channel,
                      guild_external_id: channel&.guild_external_id, channel_external_id: channel&.external_id)
      @failure = error
      Result.new(status: :failed, reason: receipt.error, delivery: receipt)
    end

    def finished(receipt)
      Result.new(status: :posted, message_id: receipt.message_external_id, url: receipt.url, delivery: receipt)
    end
  end
end
