class UnsubscribesController < ApplicationController
  skip_before_action :require_authentication

  # GET /unsubscribe/:token — inert confirm page (no state change). Prevents
  # email-scanner GET prefetch from silently unsubscribing people.
  def show
    @contact = Contact.find_by(unsubscribe_token: params[:token])
  end

  # POST /unsubscribe/:token — actually unsubscribe.
  def create
    @contact = Contact.find_by(unsubscribe_token: params[:token])
    @contact&.unsubscribe!
  end
end
