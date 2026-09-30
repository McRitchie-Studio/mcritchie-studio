# One broadcast email rendered for one contact and held: locked and loaded, not
# sent (task staged-email-queue). The row keeps a snapshot of exactly what will
# go out (recipient, subject, HTML and text, tracking links included) and the
# merge fields that made it, so what an operator previews and approves is what
# the send job delivers, byte for byte.
#
#   staged ──approve──▶ approved ──execute──▶ (queued) ──job──▶ sent
#     │                   │
#     └──────cancel───────┴──▶ cancelled        skipped: never rendered, or
#                                               dropped at send, with a reason
#
# Why a table of its own rather than a "staged" state on BroadcastDelivery: a
# delivery row counts as delivered in the analytics (Broadcast#delivered_count,
# open and click rates) the moment it exists, and a held email has been
# delivered to no one. The delivery is created only when the snapshot is sent,
# under the delivery_token the snapshot's tracking links already carry.
class StagedEmail < ApplicationRecord
  STATUSES = %w[staged approved sent cancelled skipped].freeze

  belongs_to :broadcast
  belongs_to :contact
  belongs_to :delivery, class_name: "BroadcastDelivery", foreign_key: :broadcast_delivery_id, optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :contact_id, uniqueness: { scope: :broadcast_id }

  scope :of_status, ->(status) { where(status: status) }
  # Approved, not yet handed to the send job, and due.
  scope :ready_to_send, lambda { |now = Time.current|
    where(status: "approved", queued_at: nil, sent_at: nil)
      .where("scheduled_for IS NULL OR scheduled_for <= ?", now)
  }

  def staged?    = status == "staged"
  def approved?  = status == "approved"
  def sent?      = status == "sent"
  def cancelled? = status == "cancelled"
  def skipped?   = status == "skipped"
  def queued?    = approved? && queued_at.present?

  # Render this recipient's email now and hold it as `staged`. Returns the row;
  # a contact missing a field the broadcast needs is stored `skipped` with the
  # fields named, rather than rendered with blanks.
  def render_snapshot!(now: Time.current)
    raise ArgumentError, "already sent; a sent email is never re-rendered" if sent?

    fields = Broadcasts::MergeFields.for(contact)
    missing = broadcast.required_merge_fields - fields.keys
    if missing.any?
      update!(status: "skipped", skip_reason: "missing #{missing.join(', ')}", merge_fields: fields,
              email: contact.email, rendered_subject: nil, rendered_html: nil, rendered_text: nil,
              staged_at: now, approved_at: nil, cancelled_at: nil)
      return self
    end

    self.delivery_token ||= pending_delivery_token
    message = BroadcastMailer.campaign(broadcast, contact, BroadcastDelivery.new(token: delivery_token), merge_fields: fields).message
    update!(status: "staged", skip_reason: nil, merge_fields: fields, email: contact.email,
            rendered_subject: message.subject, rendered_html: part_body(message, "text/html"),
            rendered_text: part_body(message, "text/plain"),
            staged_at: now, approved_at: nil, cancelled_at: nil, queued_at: nil)
    self
  end

  def approve!(now: Time.current)
    return self if approved?
    raise ArgumentError, "only a staged email can be approved (this one is #{status})" unless staged?

    update!(status: "approved", approved_at: now)
    self
  end

  # Stop a staged or approved email going out. One already handed to the send
  # job is left alone: the job may be mid-send.
  def cancel!(now: Time.current)
    return self if cancelled?
    raise ArgumentError, "a #{status} email cannot be cancelled" unless staged? || (approved? && !queued?)

    update!(status: "cancelled", cancelled_at: now)
    self
  end

  # Dropped at send time (the reader unsubscribed after staging, say).
  def skip!(reason)
    update!(status: "skipped", skip_reason: reason)
  end

  # The snapshot for an operator's eyes: the stored HTML, with the open pixel
  # removed and each tracked link pointed straight at its destination, so
  # looking at an email never records an open or a click against it.
  def preview_html
    html = rendered_html.to_s.gsub(%r{<img[^>]+/e/o/[^>]*>}, "")
    html.gsub(%r{https?://[^"'\s]+/e/c/[^"'\s?]+\?l=(\w+)}) { broadcast.link_for(Regexp.last_match(1)) || "#" }
  end

  # The personal values worth a glance in the queue table.
  def key_merge_fields
    merge_fields.except("email", "first_name").presence || merge_fields.slice("first_name")
  end

  private

  # The token the snapshot's tracking links carry. An unsent delivery left by
  # an earlier failed attempt keeps its token, so its row and its links agree.
  def pending_delivery_token
    BroadcastDelivery.where(broadcast: broadcast, contact: contact, sent_at: nil).pick(:token) ||
      SecureRandom.urlsafe_base64(16)
  end

  def part_body(message, mime)
    part = message.multipart? ? message.parts.find { |p| p.mime_type == mime } : (message if message.mime_type == mime)
    part&.decoded
  end
end
