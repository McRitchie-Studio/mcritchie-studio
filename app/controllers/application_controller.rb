class ApplicationController < ActionController::Base
  include Studio::ErrorHandling

  allow_browser versions: :modern

  # OPSEC-045: clear a stale/forced-out session before anything reads
  # current_user, and populate Current.user for the request lifecycle. Both
  # helpers live in Studio::ErrorHandling.
  before_action :verify_session_token
  before_action :set_current_context
end
