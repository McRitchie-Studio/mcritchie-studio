# /broadcasts/:broadcast_id/queue — the staged email queue (task
# staged-email-queue): each reader's email rendered and held, "locked and
# loaded, not sent". Staging, approving, cancelling and re-staging send
# nothing; only #execute hands approved emails to the send job, after a
# confirm step that shows the count and the send gate. Admins only: it sends
# real email.
class BroadcastQueuesController < ApplicationController
  before_action :require_admin
  before_action :load_broadcast
  before_action :load_staged_email, only: %i[preview restage]

  ROW_LIMIT = 200
  FILTERS = %w[all staged approved queued sent skipped cancelled].freeze

  # GET /broadcasts/:broadcast_id/queue[?status=approved][&confirm=execute]
  def show
    @filter = FILTERS.include?(params[:status]) ? params[:status] : "all"
    @counts = @broadcast.queue_counts
    @skip_reasons = @broadcast.skip_reasons
    @gate = Broadcasts::SendGate.status
    @ready = @broadcast.staged_emails.ready_to_send.count
    @execute_limit = execute_limit
    @confirm_execute = params[:confirm] == "execute"
    @rows = filtered_rows.includes(:contact).order(:id).limit(ROW_LIMIT)
    @total = filtered_rows.count
  end

  # POST .../queue/stage — render and hold for the audience (sends nothing).
  def stage
    audience = params[:audience].presence || @broadcast.target_list
    return redirect_to(broadcast_queue_path(@broadcast), alert: "Set the broadcast's list first.") if audience.blank?

    rescue_and_log(target: @broadcast) do
      result = @broadcast.stage!(audience: audience, limit: params[:limit].presence&.to_i)
      redirect_to broadcast_queue_path(@broadcast),
                  notice: "Staged #{result.staged}, skipped #{result.skipped}. Nothing was sent."
    end
  end

  # POST .../queue/approve — the selected rows (ids[]), or the next N held.
  def approve
    return redirect_to(back_to_queue, alert: "Select rows first.") if params[:bulk].present? && params[:ids].blank?

    rescue_and_log(target: @broadcast) do
      count = if params[:ids].present?
        @broadcast.approve_staged!(ids: Array(params[:ids]))
      else
        @broadcast.approve_staged!(count: params[:count].presence&.to_i)
      end
      redirect_to back_to_queue, notice: "Approved #{count}. Nothing is sent until you execute."
    end
  end

  # POST .../queue/cancel — the selected rows. A row already handed to the
  # send job is left alone.
  def cancel
    return redirect_to(back_to_queue, alert: "Select rows first.") if params[:ids].blank?

    rescue_and_log(target: @broadcast) do
      rows = @broadcast.staged_emails.where(id: Array(params[:ids]))
      cancelled = rows.count { |row| cancellable?(row) && row.cancel! }
      redirect_to back_to_queue, notice: "Cancelled #{cancelled}."
    end
  end

  # POST .../queue/emails/:email_id/restage — re-render one from the reader's
  # current fields (after a stats import, say).
  def restage
    rescue_and_log(target: @staged_email) do
      if @staged_email.sent? || @staged_email.queued?
        next redirect_to(back_to_queue, alert: "#{@staged_email.email} is already #{@staged_email.sent? ? 'sent' : 'queued'}.")
      end

      @staged_email.render_snapshot!
      redirect_to back_to_queue, notice: "Re-staged #{@staged_email.email}: #{@staged_email.status}."
    end
  end

  # POST .../queue/execute — send up to `limit` approved emails, within the
  # daily cap and the send gate (re-checked here, not trusted from the page).
  def execute
    rescue_and_log(target: @broadcast) do
      result = @broadcast.execute_staged!(limit: params[:limit].to_i.clamp(1, Broadcasts::SendGate::DAILY_CAP))
      if result.gate.paused? && result.queued.zero?
        redirect_to broadcast_queue_path(@broadcast), alert: "Paused: #{result.gate.reasons.join('; ')}. Nothing was sent."
      else
        redirect_to broadcast_queue_path(@broadcast),
                    notice: "Queued #{result.queued} to send, #{Broadcast::BATCH_SPACING.in_milliseconds.to_i}ms apart."
      end
    end
  end

  # GET .../queue/emails/:email_id/preview — the stored snapshot, tracking
  # disarmed (StagedEmail#preview_html). A skipped row has none.
  def preview
    if @staged_email.rendered_html.blank?
      return render plain: "Not rendered: #{@staged_email.skip_reason || @staged_email.status}", status: :not_found
    end

    render html: @staged_email.preview_html.html_safe, layout: false # rubocop:disable Rails/OutputSafety -- our own render, stored at staging
  end

  private

  def load_broadcast
    @broadcast = Broadcast.find_by!(slug: params[:broadcast_id])
  end

  def load_staged_email
    @staged_email = @broadcast.staged_emails.find(params[:email_id])
  end

  def filtered_rows
    scope = @broadcast.staged_emails
    case @filter
    when "all" then scope
    when "queued" then scope.of_status("approved").where.not(queued_at: nil)
    else scope.of_status(@filter)
    end
  end

  def cancellable?(row)
    row.staged? || (row.approved? && !row.queued?)
  end

  # The confirm step's count: what one execute would send now.
  def execute_limit
    requested = params[:limit].presence&.to_i || @ready
    [ requested, @ready, @gate.remaining ].min.clamp(0, Broadcasts::SendGate::DAILY_CAP)
  end

  def back_to_queue
    broadcast_queue_path(@broadcast, status: FILTERS.include?(params[:status]) ? params[:status] : nil)
  end
end
