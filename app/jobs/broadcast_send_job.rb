# Sends one broadcast to one contact (used for scheduled / async sends).
# Re-checks subscription at send time so a late unsubscribe is honored.
class BroadcastSendJob < ApplicationJob
  def perform(broadcast_id, contact_id)
    broadcast = Broadcast.find(broadcast_id)
    contact   = Contact.find(contact_id)
    return unless contact.subscribed?

    BroadcastMailer.campaign(broadcast, contact).deliver_now
  end
end
