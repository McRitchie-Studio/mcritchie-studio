# Where one registered report (config/report_destinations.yml) is posted: a
# Discord channel from the directory, and whether delivery is on. Alex picks it at
# /admin/report_destinations; ReportDestinations.deliver reads it
# (docs/agents/system/report-destinations.md).
class ReportDestination < ApplicationRecord
  belongs_to :discord_channel, optional: true

  validates :report_key, presence: true, uniqueness: true
  validate :report_key_registered
  validate :channel_selectable, if: -> { discord_channel_id_changed? && discord_channel }

  def self.for(report_key) = find_by(report_key: report_key.to_s)

  def registration = ReportDestinations.registration(report_key)

  private

  def report_key_registered
    return if report_key.blank? || ReportDestinations.registered?(report_key)

    errors.add(:report_key, "is not registered in config/report_destinations.yml")
  end

  # Picking is held to the same set the page offers: a seen, postable message
  # channel. A channel archived after it was picked stays on the row (deliver
  # answers :not_configured for it), but it cannot be newly chosen.
  def channel_selectable
    errors.add(:discord_channel, "is archived or not postable by the bot") unless discord_channel.selectable?
  end
end
