# Moves a launched request's intake files from intake/<token>/ to
# apps/<sub>/intake/ (AppIntakeMove). Enqueued by AppLaunch after its
# transaction commits; a request not yet queued (or rolled back) has no app, so
# the job does nothing. Retried on failure: the move is idempotent.
class AppIntakeMoveJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(app_request_id)
    request_row = AppRequest.find_by(id: app_request_id)
    return if request_row.nil? || request_row.subdomain.blank? || !AppRequest::HOLDING.include?(request_row.status)

    AppIntakeMove.new(request_row).call
  end
end
