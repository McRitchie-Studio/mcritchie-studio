# Sends one broadcast to one contact. Creates the per-recipient BroadcastDelivery
# (which carries the tracking token), then delivers. Re-checks subscription at
# send time so a late unsubscribe is honored, never mails an address a
# verification called undeliverable (even one resubscribed since), and never sends one broadcast to
# one contact twice: a delivery already stamped sent is skipped. sent_at is
# stamped only after the mailer returns, so a send that fails (a Resend rate
# limit, say) is retried rather than recorded as sent. Two jobs for the same
# pair (overlapping batches, or a batch plus the editor's send) never run at
# once: the second waits for the first, then sees sent_at and skips.
#
# Given a staged_email_id (task staged-email-queue), it sends that row's stored
# snapshot instead of rendering afresh: only an approved row goes, under the
# delivery token its tracking links were rendered with, and the same guards
# apply. The lock key is still the (broadcast, contact) pair, so a staged send
# and a batch or editor send to the same reader never overlap either.
class BroadcastSendJob < ApplicationJob
  limits_concurrency to: 1, key: ->(broadcast_id, contact_id, *) { "#{broadcast_id}-#{contact_id}" }

  def perform(broadcast_id, contact_id, staged_email_id = nil)
    broadcast = Broadcast.find(broadcast_id)
    contact   = Contact.find(contact_id)
    return perform_staged(broadcast, contact, StagedEmail.find(staged_email_id)) if staged_email_id

    return unless contact.subscribed?
    return if contact.undeliverable?

    delivery = broadcast.deliveries.find_or_create_by!(contact: contact)
    return if delivery.sent_at.present?

    message = BroadcastMailer.campaign(broadcast, contact, delivery).deliver_now
    record_sent!(delivery, message)
  end

  private

  def perform_staged(broadcast, contact, staged)
    return unless staged.approved? && staged.broadcast_id == broadcast.id && staged.contact_id == contact.id
    return staged.skip!("unsubscribed before send") unless contact.subscribed?
    return staged.skip!("undeliverable before send") if contact.undeliverable?

    delivery = broadcast.deliveries.find_or_create_by!(contact: contact) { |d| d.token = staged.delivery_token }
    return staged.skip!("already sent by another send") if delivery.sent_at.present?

    # An unsent delivery from an earlier attempt takes the snapshot's token,
    # so the links in the email are the ones its events land on.
    delivery.update!(token: staged.delivery_token) if staged.delivery_token.present? && delivery.token != staged.delivery_token

    message = BroadcastMailer.staged(staged).deliver_now
    record_sent!(delivery, message)
    staged.update!(status: "sent", sent_at: delivery.sent_at, delivery: delivery)
  end

  def record_sent!(delivery, message)
    delivery.update!(sent_at: Time.current)
    # Resend's mailer puts its email id in message_id; its webhooks name it.
    delivery.update!(provider_message_id: message.message_id) if message&.message_id.present?
    delivery.record_event!(kind: "sent", source: "app")
  end
end
