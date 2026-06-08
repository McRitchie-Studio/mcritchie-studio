class BroadcastsController < ApplicationController
  # Sends real email to the subscriber list — admins only.
  before_action :require_admin

  before_action :load_broadcast, only: %i[edit update preview deliver]

  # GET /broadcasts — table view of all emails.
  def index
    @broadcasts = Broadcast.recent
  end

  # GET /broadcasts/:id/edit — the email editor (form + live preview + stats).
  def edit
    @audiences  = audience_counts
    @deliveries = @broadcast.deliveries.includes(:contact).order(clicked_at: :desc, opened_at: :desc, sent_at: :desc)
  end

  # POST /broadcasts/:id/deliver — queue this broadcast to an audience. Each
  # recipient is sent via BroadcastSendJob (async) so the request returns fast
  # and a late unsubscribe is re-checked at send time.
  def deliver
    if @broadcast.sent?
      return redirect_to edit_broadcast_path(@broadcast), alert: "Already sent — duplicate send blocked."
    end

    contacts = audience_scope(params[:audience])
    count = contacts.count
    if count.zero?
      return redirect_to edit_broadcast_path(@broadcast), alert: "No subscribed contacts in that audience."
    end

    contacts.find_each { |c| BroadcastSendJob.perform_later(@broadcast.id, c.id) }
    @broadcast.update!(status: "sent", sent_at: Time.current)
    redirect_to edit_broadcast_path(@broadcast), notice: "Queued to #{count} subscriber#{'s' unless count == 1}."
  end

  # PATCH /broadcasts/:id
  def update
    if @broadcast.update(broadcast_params)
      redirect_to edit_broadcast_path(@broadcast), notice: "Saved."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # GET /broadcasts/:id/preview — renders the email in the branded shell, used
  # as the editor's iframe source and as the Copy-HTML source for HubSpot.
  def preview
    # Images need absolute, publicly-reachable URLs. In-app preview uses the
    # local host (fast iteration); ?assets=s3 uses the public S3 bucket — that's
    # what the HubSpot-bound HTML must use so images load in the inbox.
    @hubspot_export   = params[:assets] == "s3"
    @email_asset_host = @hubspot_export ? Broadcasts::Assets.base_url : request.base_url
    render template: "broadcasts/#{@broadcast.template_key}", layout: "broadcast_email"
  end

  private

  def load_broadcast
    @broadcast = Broadcast.find_by!(slug: params[:id])
  end

  def audience_scope(audience)
    audience.to_s == "all" ? Contact.subscribed : Contact.subscribed.with_tag(audience.to_s)
  end

  def audience_counts
    # One query: pluck every subscribed contact's tags, then derive counts in Ruby
    # (row count = "all", flattened tag tally = per-tag counts).
    all_tags = Contact.subscribed.pluck(:tags)
    { "all" => all_tags.size }.merge(all_tags.flatten.tally.sort.to_h)
  end

  def broadcast_params
    # `status` is intentionally NOT permitted — it's derived from #deliver, not
    # hand-editable (so the index "Status" column can't lie).
    params.require(:broadcast).permit(
      :subject, :preview_text, :header, :subheader, :template_key, :target_list,
      :hero_url, :survivor_url, :turf_totals_url
    )
  end
end
