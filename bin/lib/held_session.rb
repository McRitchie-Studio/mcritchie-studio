# frozen_string_literal: true

require "time"
require_relative "admin_login"
require_relative "desk_session"
require_relative "session_identity"
require_relative "projects_root"
require_relative "../../lib/task_usage_sandbox"

# HeldSession: the agent logins a harness session can present right now
# (docs/agents/system/agent-sessions-design.md, section 3), for the callers that
# are not `bin/task`: the narration CLI, the capture hooks and the release
# conductor's claim.
#
# Two places hold one, and only the harness session that logged in reads either:
#
# - the desk the command runs in (`bin/task begin` wrote DeskSession's file): a
#   studio login to that desk's task;
# - the admin login: `AGENT_ADMIN_SESSION_TOKEN` (the hub-shell grant, whose soul
#   is not known here), else the AdminLogin file `heartbeat steffon|xan` collected.
#
# Each login is `{ "token", "tier", "soul", "slug" }`. The token is a bearer
# credential: callers present it and never print it.
#
# Every agent a harness spawns shares its harness session id, so a login found
# here may belong to another agent of the same harness. A caller that records an
# actor asks for the login by `soul:` and presents it only on a match, so a
# login never restamps what the caller would have declared.
module HeldSession
  ADMIN_ENV = "AGENT_ADMIN_SESSION_TOKEN"

  module_function

  # The logins held, the narrowest first: the desk's, then the admin's.
  def all(env:, projects_dir:, session_id: nil, cwd: Dir.pwd, now: Time.now)
    sid = session_id.to_s.strip
    sid = SessionIdentity.id(env) if sid.empty?
    [desk(env, sid, cwd, now), admin(env, sid, projects_dir, now)].compact
  rescue StandardError
    []
  end

  # The first login held that matches `soul` and `tier` (nil matches any), or nil.
  def find(env:, projects_dir:, soul: nil, tier: nil, **options)
    all(env: env, projects_dir: projects_dir, **options).find do |login|
      (soul.nil? || login["soul"] == soul.to_s) && (tier.nil? || login["tier"] == tier.to_s)
    end
  end

  def admin(env, sid, projects_dir, now)
    explicit = env[ADMIN_ENV].to_s.strip
    return { "token" => explicit, "tier" => "admin", "soul" => nil, "slug" => nil } unless explicit.empty?
    return nil if sid.empty?

    token = AdminLogin.token_for(sid, projects_dir, now: now)
    data = token && AdminLogin.read(sid, projects_dir)
    data && { "token" => token, "tier" => "admin", "soul" => data["soul"], "slug" => data["session"] }
  end

  def desk(env, sid, cwd, now)
    root = DeskSession.root_for(cwd)
    return nil if sid.empty? || root.nil? || sandboxed_away?(root, env)

    data = DeskSession.read(root)
    return nil unless data && data["harness_session_id"].to_s == sid
    return nil if data["token"].to_s.empty? || !DeskSession.live?(data, now)

    { "token" => data["token"], "tier" => data["tier"] || "studio", "soul" => data["soul"], "slug" => data["slug"] }
  end

  # A sandboxed process (a test run) never presents a login kept in one of the
  # operator's real checkouts.
  def sandboxed_away?(root, env)
    TaskUsageSandbox.active?(TaskUsageSandbox.guard_env(env)) &&
      TaskUsageSandbox.inside?(root, ProjectsRoot.default_projects_dir)
  end
end
