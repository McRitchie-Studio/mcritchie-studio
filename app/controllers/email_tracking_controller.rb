# Public engagement endpoints hit from inside sent emails. No auth — they're
# reached by recipients' mail clients/browsers, keyed by an opaque delivery token.
class EmailTrackingController < ApplicationController
  skip_before_action :require_authentication

  # 1x1 transparent GIF.
  PIXEL = Base64.decode64("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7").freeze

  # GET /e/o/:token — open pixel.
  def open
    delivery = BroadcastDelivery.find_by(token: params[:token])
    delivery&.record_open!(machine: machine?(delivery), data: { "user_agent" => request.user_agent.to_s.first(255) })
    response.set_header("Cache-Control", "no-store, no-cache, must-revalidate, private")
    send_data PIXEL, type: "image/gif", disposition: "inline"
  end

  # GET /e/c/:token?l=<link-key> — log the click, then redirect to the resolved
  # destination. The key resolves server-side via Broadcast#link_for, so this
  # can't be turned into an open redirect.
  def click
    delivery = BroadcastDelivery.find_by(token: params[:token])
    url = delivery&.broadcast&.link_for(params[:l])
    if url
      delivery.record_click!(link_key: params[:l].to_s, machine: machine?(delivery),
                             data: { "user_agent" => request.user_agent.to_s.first(255) })
    end
    redirect_to(url.presence || root_url, allow_other_host: true)
  end

  private

  def machine?(delivery)
    EmailEvents::MachineDetector.machine?(user_agent: request.user_agent, sent_at: delivery&.sent_at,
                                          method: request.request_method)
  end
end
