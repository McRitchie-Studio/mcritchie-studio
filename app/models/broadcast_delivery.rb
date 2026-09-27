# One row per (broadcast, contact) recipient. Holds the send + engagement state
# (opens, clicks) and the opaque token embedded in the tracking pixel + click
# links, so every open/click is attributable to a specific contact.
#
# Every open, click, delivery report, bounce, complaint and unsubscribe is also
# written to the event log (EmailEvent) through #record_event!, which keeps the
# first time of each on this row: the dashboard reads these rollups.
# `provider_message_id` is Resend's id for the sent email, the key its webhooks
# name.
class BroadcastDelivery < ApplicationRecord
  belongs_to :broadcast
  belongs_to :contact
  has_many :events, class_name: "EmailEvent", dependent: :destroy

  before_validation :ensure_token, on: :create
  validates :token, presence: true

  # The first-time column each kind of event stamps.
  FIRST_AT = {
    "delivered" => :delivered_at,
    "bounced" => :bounced_at,
    "complained" => :complained_at,
    "unsubscribed" => :unsubscribed_at
  }.freeze

  def record_open!(machine: false, source: "pixel", at: Time.current, data: {})
    record_event!(kind: "opened", source: source, machine: machine, at: at, data: data)
  end

  def record_click!(link_key: nil, machine: false, source: "redirect", at: Time.current, data: {})
    record_event!(kind: "clicked", source: source, machine: machine, link_key: link_key, at: at, data: data)
  end

  # Log one event and roll it up onto this row. A webhook redelivered under
  # the same provider_event_id is recorded once; the repeat returns nil.
  def record_event!(kind:, source:, at: Time.current, machine: false, link_key: nil, provider_event_id: nil, data: {})
    return nil if provider_event_id.present? && EmailEvent.exists?(provider_event_id: provider_event_id)

    transaction do
      event = events.create!(kind: kind, source: source, machine: machine, link_key: link_key,
                             provider_event_id: provider_event_id, occurred_at: at, data: data)
      roll_up!(event)
      event
    end
  rescue ActiveRecord::RecordNotUnique
    nil
  end

  private

  def roll_up!(event)
    now = Time.current
    changes = { updated_at: now }
    at = event.occurred_at

    case event.kind
    when "opened"
      # Resend reports opens too; count only our pixel's, so turning on
      # Resend's tracking can never double the open count.
      if event.source == "pixel"
        changes[:opened_at] = opened_at || at
        changes[:open_count] = open_count + 1
        changes[:human_opened_at] = human_opened_at || at unless event.machine
      end
    when "clicked"
      if event.source == "redirect"
        changes[:clicked_at] = clicked_at || at
        changes[:click_count] = click_count + 1
        changes[:human_clicked_at] = human_clicked_at || at unless event.machine
      end
    when "bounced"
      changes[:bounced_at] = bounced_at || at
      changes[:bounce_kind] = event.data["bounce_kind"] if bounce_kind.blank?
    else
      column = FIRST_AT[event.kind]
      changes[column] = self[column] || at if column
    end

    update_columns(changes)
  end

  def ensure_token
    self.token ||= SecureRandom.urlsafe_base64(16)
  end
end
