# The CTO web chat's files (AgentMessages::Attachments; .agents/epics/chat-media-design.md):
#
#   create  POST /applications/:slug/chat/attachments   one file from the composer
#           (multipart `file`). The type is read from the bytes and the size
#           checked, the file is stored in R2 under apps/<slug>/chat/, and the
#           answer is JSON: a signed TOKEN the form sends with the message, never
#           a blob URL. 422 with error and error_code when a rule refuses it.
#   show    GET /applications/:slug/chat/attachments/:attachment_id  one SENT file:
#           a redirect to an R2 URL that expires in Attachments::URL_TTL, for the
#           thread's owner or an admin only (`?download=1` saves it instead).
#
# Past the AdminWall (SIGNED_IN), both answer 404, never 403, unless the viewer
# owns the app or is an admin, exactly as the chat does; a file on another
# person's thread is a 404 to everyone but an admin.
class CtoChatAttachmentsController < ApplicationController
  include ActiveStorage::SetCurrent

  before_action :load_app

  def create
    upload = params[:file]
    outcome = rescue_and_log(target: @app) do
      AgentMessages::Attachments.upload!(io: upload.respond_to?(:tempfile) ? upload.tempfile : nil,
                                         filename: upload.respond_to?(:original_filename) ? upload.original_filename : nil,
                                         app_slug: @app.slug, user: current_user)
    rescue AgentMessages::Attachments::Refused => e
      e
    end
    if outcome.is_a?(AgentMessages::Attachments::Refused)
      return render json: { error: outcome.message, error_code: outcome.code }, status: :unprocessable_content
    end

    render json: { token: AgentMessages::Attachments.token_for(outcome), filename: outcome.filename.to_s,
                   content_type: outcome.content_type, byte_size: outcome.byte_size,
                   kind: AgentMessages::Attachments.kind(outcome.content_type) }, status: :created
  end

  def show
    attachment = ActiveStorage::Attachment.find_by(id: params[:attachment_id], record_type: "AgentMessage")
    raise ActiveRecord::RecordNotFound, "no such file" unless
      AgentMessages::Attachments.visible_to?(attachment, app_slug: @app.slug, user: current_user)

    response.headers["Cache-Control"] = "private, no-store"
    disposition = params[:download].present? ? :attachment : :inline
    redirect_to attachment.blob.url(expires_in: AgentMessages::Attachments::URL_TTL, disposition: disposition),
                allow_other_host: true
  end

  private

  def load_app
    @app = App.find_by(slug: params[:slug])
    raise ActiveRecord::RecordNotFound, "no such app" unless @app && AppOwnership.manage_app?(current_user, @app.slug)
    raise ActiveRecord::RecordNotFound, "no web chat" unless AgentMessages::WebIngest.available?(AppOwnership.cto_for_app(@app.slug))
  end
end
