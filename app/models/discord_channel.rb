# One Discord channel or active thread the agents' bot can see, mirrored by
# DiscordChannelSyncJob (docs/agents/system/report-destinations.md). Ids are
# Discord snowflakes, kept as strings. A channel the sync stops seeing is
# archived, never deleted, so a ReportDestination pointing at it never dangles.
#
# NOT the DiscordChannels module (app/models/discord_channels.rb): that one names
# the two webhook LANES (external, internal) some posters still use, by ENV. This
# is the bot's live directory of a guild's real channels, synced from Discord.
class DiscordChannel < ApplicationRecord
  KINDS = %w[text announcement forum thread voice category].freeze
  # The kinds a plain message can be posted into. A forum takes posts only as
  # new threads, and a voice or category channel takes none from a report.
  MESSAGE_KINDS = %w[text announcement thread].freeze

  has_many :report_destinations, dependent: :nullify

  validates :guild_external_id, :external_id, :name, presence: true
  validates :kind, inclusion: { in: KINDS }
  validates :external_id, uniqueness: { scope: :guild_external_id }

  scope :active, -> { where(archived_at: nil) }
  scope :in_guild, ->(guild_id) { where(guild_external_id: guild_id.to_s) }
  # A destination can be any of these: seen on the last sync, a message kind,
  # and the bot may view and send there.
  scope :selectable, -> { active.where(postable: true, kind: MESSAGE_KINDS) }
  scope :directory_order, -> { order(Arel.sql("COALESCE(category_name, '') ASC"), :position, :name) }

  def archived? = archived_at.present?
  def selectable? = !archived? && postable? && MESSAGE_KINDS.include?(kind)

  # "#name" for a channel, "↳ name" for a thread (the page adds its parent).
  def display_name
    prefix = kind == "thread" ? "↳ " : "#"
    "#{prefix}#{name}"
  end

  def url = "https://discord.com/channels/#{guild_external_id}/#{external_id}"
end
