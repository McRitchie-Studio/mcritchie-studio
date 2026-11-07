# The hub's session cookie options (config/initializers/session_store.rb; task
# qa-own-session-cookie).
#
# Production sets _studio_session on .mcritchie.studio, so the hub's sign-in
# can reach every *.mcritchie.studio app (the groundwork for single sign-on).
# QA boots RAILS_ENV=production too, and qa.mcritchie.studio sits under that
# same domain. With one name and one domain, the two apps wrote the same
# cookie: signing in to QA signed Alex McRitchie out of production and back
# (2026-11-07). QA is told apart by QA_ENV=true (Studio::EnvironmentBanner),
# so it takes its own name and a host-only cookie, and the two never meet.
# Each place has its own name (Alex McRitchie, 2026-11-07: "specific cookies for
# prod, qa and any local version"): _studio_session, _studio_qa_session and
# _studio_local_session (a desk adds its task slug).
#
# Pure: takes the environment, so test/lib/session_cookie_test.rb runs it
# without booting Rails in each mode.
module SessionCookie
  PRODUCTION_KEY = "_studio_session".freeze
  QA_KEY = "_studio_qa_session".freeze
  LOCAL_KEY = "_studio_local_session".freeze
  PRODUCTION_DOMAIN = ".mcritchie.studio".freeze

  module_function

  # production: Rails.env.production?; qa: the QA_ENV marker is truthy.
  def options(production:, qa:, env: ENV)
    base = { httponly: true, same_site: :lax }
    if production && qa
      # No domain: a host-only cookie, sent to qa.mcritchie.studio alone.
      base.merge(key: QA_KEY, secure: true)
    elsif production
      base.merge(key: PRODUCTION_KEY, domain: PRODUCTION_DOMAIN, secure: true)
    else
      # Desks set MCRITCHIE_SESSION_KEY (bin/agent-worktree: LOCAL_KEY plus the
      # task slug) so two local servers keep apart.
      base.merge(key: env.fetch("MCRITCHIE_SESSION_KEY", LOCAL_KEY), domain: :all, secure: false)
    end
  end
end
