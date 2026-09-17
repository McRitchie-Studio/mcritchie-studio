# One arrival at team@mcritchie.studio — the knowledge-capture front door.
# The Resend inbound webhook's ingest job creates these (the SES poller remains
# only as a fallback); the capture sweep (an agent running the knowledge-capture
# SOP) files them onward into an entity's knowledge layer and stamps the outcome.
class DeskCaptureItem < ApplicationRecord
  STATUSES = %w[received quarantined filed ignored].freeze

  # Which door the item came through. Not cosmetic — it decides whether the
  # sender allowlist below applies (see DeskCapture::TRUSTED_SOURCES).
  #   resend — the team@ inbound webhook (primary)
  #   ses    — the legacy bucket poller (fallback)
  #   gmail  — the alex@ mailbox read (Gmail::MailboxIngest)
  SOURCES = %w[resend ses gmail].freeze

  validates :s3_key, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validates :source, inclusion: { in: SOURCES }

  scope :awaiting_sweep, -> { where(status: "received").order(received_at: :asc) }
  scope :recent_first,   -> { order(received_at: :desc) }
  scope :from_gmail,     -> { where(source: "gmail") }

  # The Gmail read's resume point: the newest change we have DURABLY RECORDED,
  # never a separately stored cursor. A pull that crashes after fetching but
  # before saving leaves this untouched, so the next run re-reads that window
  # instead of stepping over it. Nil means "no Gmail item yet" — the caller
  # then runs its bounded backfill rather than guessing a cursor.
  def self.gmail_cursor
    from_gmail.maximum(:history_id)
  end

  # Only mail from these senders is parsed and swept — everything else is
  # quarantined with its raw kept and its attachments left unextracted. An open
  # capture inbox at a guessable address is otherwise an injection vector
  # straight into the deal room.
  #
  # This is the PUBLIC door's rule and stays exactly as strict as it is. The
  # Gmail read does not widen it — a message already sitting in Mr. McRitchie's
  # own mailbox, selected by a query we control, has different provenance from
  # mail anyone can address to team@. That distinction lives in
  # DeskCapture::TRUSTED_SOURCES, keyed on the TRANSPORT (which our code picks),
  # never on a header in the mail (which a stranger can forge).
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
