require "test_helper"

# [integration] The session cookie a real request sets carries this
# environment's own name (task qa-own-session-cookie): the initializer wires
# SessionCookie.options into the app, so a visit to the sign-in page sets the
# local name here, never production's _studio_session. A magic-link request
# for an unknown address sets a flash, which writes the session cookie.
class SessionCookieNameTest < ActionDispatch::IntegrationTest
  test "[integration] the app's session cookie is the one SessionCookie names for this environment" do
    expected = SessionCookie.options(production: false, qa: false)[:key]

    assert_equal expected, Rails.application.config.session_options[:key]
    post magic_link_request_path, params: { email: "nobody@example.com" }

    assert_response :redirect
    set_cookie = Array(response.headers["Set-Cookie"]).join("\n")
    assert_match(/\A#{Regexp.escape(expected)}=|\n#{Regexp.escape(expected)}=/, set_cookie, "the response sets #{expected}")
    assert_no_match(/(\A|\n)_studio_session=/, set_cookie, "a local server never writes production's cookie name") unless expected == "_studio_session"
  end
end

# [integration] Each mode's options, run through the real cookie store on a tiny
# Rack app, set the cookie the browser keeps: QA host-only under its own name,
# production on .mcritchie.studio. The test env cannot boot production, so this
# is the closest a test gets to the header each live app sends.
class SessionCookieHeaderTest < ActiveSupport::TestCase
  def set_cookie_for(options)
    app = ->(env) { env["rack.session"]["probe"] = 1; [ 200, {}, [ "ok" ] ] }
    store = ActionDispatch::Session::CookieStore.new(app, **options)
    env = Rack::MockRequest.env_for("https://qa.mcritchie.studio/", "HTTPS" => "on")
    env.merge!(Rails.application.env_config)
    _, headers, = ActionDispatch::Cookies.new(store).call(env)
    Array(headers["set-cookie"]).join("\n")
  end

  test "[integration] QA's Set-Cookie is host-only _studio_qa_session" do
    header = set_cookie_for(SessionCookie.options(production: true, qa: true))

    assert_match(/\A_studio_qa_session=/, header)
    assert_no_match(/domain=/i, header)
    assert_match(/secure/i, header)
    assert_match(/httponly/i, header)
  end

  test "[integration] production's Set-Cookie is _studio_session on .mcritchie.studio" do
    header = set_cookie_for(SessionCookie.options(production: true, qa: false))

    assert_match(/\A_studio_session=/, header)
    assert_match(/domain=\.mcritchie\.studio/i, header)
  end
end
