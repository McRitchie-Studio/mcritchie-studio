# One arrival at desk@mcritchie.studio — the knowledge-capture front door.
# The poller creates these from SES's S3 drops; the capture sweep (an agent
# running the knowledge-capture SOP) files them onward into an entity's
# knowledge layer and stamps the outcome.
class DeskCaptureItem < ApplicationRecord
  STATUSES = %w[received quarantined filed ignored].freeze

  validates :s3_key, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }

  scope :awaiting_sweep, -> { where(status: "received").order(received_at: :asc) }
  scope :recent_first,   -> { order(received_at: :desc) }

  # Only mail from these senders is parsed and swept — everything else is
  # quarantined with its raw kept and its attachments left unextracted. An open
  # capture inbox at a guessable address is otherwise an injection vector
  # straight into the deal room.
  def self.allowed_senders
    ENV.fetch("DESK_ALLOWED_SENDERS", "amcritchie@gmail.com,alex@mcritchie.studio")
       .split(",").map { |s| s.strip.downcase }.reject(&:empty?)
  end

  def self.allowlisted?(addr)
    allowed_senders.include?(addr.to_s.strip.downcase)
  end

  def quarantined? = status == "quarantined"

  def attachment_count
    attachments.is_a?(Array) ? attachments.size : 0
  end
end
