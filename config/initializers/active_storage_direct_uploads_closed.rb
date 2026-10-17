# Active Storage's stock direct-upload endpoint (POST /rails/active_storage/direct_uploads)
# is OUTSIDE the AdminWall by construction: it creates a blob for any visitor and
# answers a presigned PUT into the hub's R2 bucket, which a non-browser client can
# use whatever the bucket's CORS says. Nothing on the hub uploads through it: the
# chat's files go through CtoChatAttachmentsController (owner or admin, server-built
# key, type read from the bytes; AgentMessages::Attachments). So it answers 404 to
# everyone. A feature that wants direct upload adds its own gated endpoint.
Rails.application.config.to_prepare do
  ActiveStorage::DirectUploadsController.class_eval do
    before_action { head :not_found }
  end
end
