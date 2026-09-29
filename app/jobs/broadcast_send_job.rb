# Sends one broadcast to one contact. Creates the per-recipient BroadcastDelivery
# (which carries the tracking token), then delivers. Re-checks subscription at
# send time so a late unsubscribe is honored, and never sends one broadcast to
# one contact twice: a delivery already stamped sent is skipped. sent_at is
# stamped only after the mailer returns, so a send that fails (a Resend rate
# limit, say) is retried rather than recorded as sent. Two jobs for the same
# pair (overlapping batches, or a batch plus the editor's send) never run at
# once: the second waits for the first, then sees sent_at and skips.
class BroadcastSendJob < ApplicationJob
  limits_concurrency to: 1, key: ->(broadcast_id, contact_id) { "#{broadcast_id}-#{contact_id}" }

  def perform(broadcast_id, contact_id)
    broadcast = Broadcast.find(broadcast_id)
    contact   = Contact.find(contact_id)
    return unless contact.subscribed?

    delivery = broadcast.deliveries.find_or_create_by!(contact: contact)
    return if delivery.sent_at.present?

    message = BroadcastMailer.campaign(broadcast, contact, delivery).deliver_now
    delivery.update!(sent_at: Time.current)
    # Resend's mailer puts its email id in message_id; its webhooks name it.
    delivery.update!(provider_message_id: message.message_id) if message&.message_id.present?
    delivery.record_event!(kind: "sent", source: "app")
  end
end
