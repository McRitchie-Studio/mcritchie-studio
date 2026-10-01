class ApplicationController < ActionController::Base
  # Preview fetchers (iMessage, Slack, Discord, X...) get a slim page under
  # Apple's 1 MiB limit. studio-engine docs/LINK_PREVIEW.md.
  include Studio::LinkPreviewBots
  include Studio::ErrorHandling

  # Preview fetchers skip the browser guard. iMessage's LinkPresentation sends a
  # pinned Safari 9 UA with the bot tokens appended ("... Version/9.0.1
  # Safari/601.2.4 facebookexternalhit/1.1 Facebot Twitterbot/1.0", captured
  # 2026-09-30), which :modern answers with a 406, so the link never unfurls
  # (WebKitErrorDomain 102). The predicate is the engine's allow-list, GET/HEAD
  # only, and a matched request only ever receives the slim, script-free page.
  allow_browser versions: :modern, unless: :link_preview_bot_request?

  # OPSEC-045: clear a stale/forced-out session before anything reads
  # current_user, and populate Current.user for the request lifecycle.
  # Implementations live in Studio::ErrorHandling.
  before_action :verify_session_token
  before_action :set_current_context
end
