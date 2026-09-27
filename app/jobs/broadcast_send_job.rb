# Sends one broadcast to one contact. Creates the per-recipient BroadcastDelivery
# (which carries the tracking token), then delivers. Re-checks subscription at
# send time so a late unsubscribe is honored.
class BroadcastSendJob < ApplicationJob
  def perform(broadcast_id, contact_id)
    broadcast = Broadcast.find(broadcast_id)
    contact   = Contact.find(contact_id)
    return unless contact.subscribed?

    delivery = broadcast.deliveries.find_or_create_by!(contact: contact)
    delivery.update!(sent_at: Time.current)
    message = BroadcastMailer.campaign(broadcast, contact, delivery).deliver_now
    # Resend's mailer puts its email id in message_id; its webhooks name it.
    delivery.update!(provider_message_id: message.message_id) if message&.message_id.present?
    delivery.record_event!(kind: "sent", source: "app")
  end
end
