# The unsubscribe links in every broadcast (task unsubscribe-and-resubscribe),
# keyed by the contact's opaque unsubscribe token. `d` names the delivery the
# reader came from, so the page can say which email it was and the analytics
# can credit the unsubscribe (or the change of heart) to it.
#
#   GET  /unsubscribe/:token              the confirm page: the address, the
#                                          email, one button. Inert, so a mail
#                                          scanner's prefetch unsubscribes no one.
#   POST /unsubscribe/:token              unsubscribe; also the RFC 8058 one-click
#                                          target a mail client POSTs to from the
#                                          List-Unsubscribe header, which carries
#                                          no form token (the unsubscribe token is
#                                          the proof).
#   POST /unsubscribe/:token/resubscribe  the landing page's change-of-heart button.
#
# Both POSTs answer with a page, not a redirect (the one-click POST must not
# redirect), so the buttons submit with Turbo off: Turbo will not render a
# form response that is not a redirect.
class UnsubscribesController < ApplicationController
  skip_before_action :require_authentication
  skip_forgery_protection only: :create
  before_action :load_contact

  def show; end

  def create
    return unless @contact

    was_subscribed = @contact.subscribed?
    @contact.unsubscribe!
    @delivery&.record_event!(kind: "unsubscribed", source: "page") if was_subscribed
  end

  def resubscribe
    return render(:create) unless @contact

    was_unsubscribed = !@contact.subscribed?
    @contact.resubscribe!
    @delivery&.record_event!(kind: "resubscribed", source: "page") if was_unsubscribed
  end

  private

  def load_contact
    @contact = Contact.find_by(unsubscribe_token: params[:token].to_s)
    @delivery = @contact && params[:d].is_a?(String) && params[:d].present? ? @contact.deliveries.includes(:broadcast).find_by(token: params[:d]) : nil
  end
end
