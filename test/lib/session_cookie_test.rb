require "test_helper"

# [unit] QA and production write different session cookies (task
# qa-own-session-cookie). Both boot RAILS_ENV=production and qa.mcritchie.studio
# sits under .mcritchie.studio, so one name on one domain let each app overwrite
# the other's sign-in.
class SessionCookieTest < ActiveSupport::TestCase
  test "[unit] production keeps _studio_session on .mcritchie.studio" do
    options = SessionCookie.options(production: true, qa: false)

    assert_equal "_studio_session", options[:key]
    assert_equal ".mcritchie.studio", options[:domain]
    assert options[:secure]
    assert options[:httponly]
    assert_equal :lax, options[:same_site]
  end

  test "[unit] QA takes its own name and a host-only cookie" do
    options = SessionCookie.options(production: true, qa: true)

    assert_equal "_studio_qa_session", options[:key]
    assert_not options.key?(:domain), "a domain would share the cookie with production again"
    assert options[:secure]
    assert options[:httponly]
  end

  test "[unit] QA and production never share a name" do
    qa = SessionCookie.options(production: true, qa: true)
    production = SessionCookie.options(production: true, qa: false)

    assert_not_equal qa[:key], production[:key]
  end

  test "[unit] a desk keeps its own key from MCRITCHIE_SESSION_KEY" do
    options = SessionCookie.options(production: false, qa: false, env: { "MCRITCHIE_SESSION_KEY" => "_studio_session_desk" })

    assert_equal "_studio_session_desk", options[:key]
    assert_equal :all, options[:domain]
    assert_not options[:secure]
    assert_equal "_studio_local_session", SessionCookie.options(production: false, qa: false, env: {})[:key]
  end

  test "[unit] production, QA and local each have their own name" do
    names = [ SessionCookie.options(production: true, qa: false), SessionCookie.options(production: true, qa: true),
              SessionCookie.options(production: false, qa: false, env: {}) ].map { |o| o[:key] }

    assert_equal %w[_studio_session _studio_qa_session _studio_local_session], names
  end

  test "[unit] QA_ENV is read the engine's way" do
    assert Studio::EnvironmentBanner.qa_environment?({ "QA_ENV" => "true" })
    assert_not Studio::EnvironmentBanner.qa_environment?({})
  end
end
