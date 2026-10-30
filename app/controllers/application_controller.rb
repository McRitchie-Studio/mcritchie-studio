class ApplicationController < ActionController::Base
  # Preview fetchers (iMessage, Slack, Discord, X...) get a slim page under
  # Apple's 1 MiB limit. studio-engine docs/LINK_PREVIEW.md.
  include Studio::LinkPreviewBots
  include Studio::ErrorHandling
  # After ErrorHandling: a foreign key or unique-index refusal answers 422.
  include ConstraintViolationResponses

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

  # A web request may spend ten seconds looking image hosts up, no more. On the
  # next engine each URL-guard judgement is a DNS lookup of up to six seconds, and
  # a page that judges several dead names would otherwise cross Heroku's thirty.
  # Jobs set no budget. Appearances::FetchableUrl.
  before_action { Appearances::FetchableUrl.limit_lookups }

  # Default-deny: every action needs an admin unless AdminWall lists it.
  include AdminWall

  helper_method :first_name_modal?, :type_dense_page?

  private

  # Whether the page reads the type scale's 14px dense base (task
  # hub-adopts-type-scale): the layout puts `type-dense` on <body>, not <html>,
  # where the theme tag's unlayered :root rule would win. Dense means admin-only,
  # the pages AdminWall walls for everyone else; a visitor's page and a signed-in
  # customer's own pages (profile, their apps, the CTO chat) keep the 16px base.
  def type_dense_page?
    !AdminWall.public?(controller_path, action_name) && !AdminWall.signed_in?(controller_path, action_name)
  end

  # Whether the layout arms the engine's first-name modal on this page: the
  # engine's rule (Studio.first_name_outstanding?), unless the page asks for the
  # name itself and opted out with skip_first_name_modal! (the CTO chat asks in
  # its own thread: AgentMessages::FirstNameAsk, task cto-chat-quality-pass).
  def first_name_modal?
    !@skip_first_name_modal && logged_in? && Studio.first_name_outstanding?(current_user, session)
  end

  # A page that asks for the first name in its own way keeps the modal off itself.
  def skip_first_name_modal! = @skip_first_name_modal = true

  # Sign-out (the engine's SessionsController#destroy) and a forced re-login
  # (verify_session_token) both end here. Neither rotates the user's token, so
  # the socket this browser opened would stay identified as the user; dropping
  # the user's sockets makes each one reconnect and re-run the connect check,
  # which this browser's now-empty session fails and the user's other live
  # sessions pass. /tasks/cable-drops-revoked-sockets.
  def clear_app_session
    user_id = session[Studio.session_key]
    super
    ApplicationCable::Connection.disconnect(User.find_by(id: user_id)) if user_id.present?
  end
end
