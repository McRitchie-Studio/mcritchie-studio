class ApplicationController < ActionController::Base
  # Preview fetchers (iMessage, Slack, Discord, X...) get a slim page under
  # Apple's 1 MiB limit. studio-engine docs/LINK_PREVIEW.md.
  include Studio::LinkPreviewBots
  include Studio::ErrorHandling

  allow_browser versions: :modern

  # OPSEC-045: clear a stale/forced-out session before anything reads
  # current_user, and populate Current.user for the request lifecycle.
  # Implementations live in Studio::ErrorHandling.
  before_action :verify_session_token
  before_action :set_current_context
end
