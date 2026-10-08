# frozen_string_literal: true

require "json"
require "time"
require_relative "session_markers"

# AdminLogin: the admin login a harness session holds
# (docs/agents/system/agent-sessions-design.md, section 3).
#
# `bin/agent-activity heartbeat steffon|xan` posts an admin login request and keeps
# its slug and collect key here; once the operator grants it, the collected session
# token replaces them. One file per harness session, in the session-marker store,
# owner-only. The token is a bearer credential: it lives in the file, never on
# stdout.
module AdminLogin
  SUFFIX = ".admin-login"
  SOULS = %w[steffon xan].freeze
  # Stop using a token this many seconds before its session expires.
  REFRESH_MARGIN = 60
  # The longest `--wait`, and the pause between collect attempts, in seconds.
  MAX_WAIT = 600
  POLL_SECONDS = 5

  module_function

  def read(session_id, projects_dir)
    data = JSON.parse(SessionMarkers.read(session_id, projects_dir, SUFFIX).to_s)
    data.is_a?(Hash) ? data : nil
  rescue StandardError
    nil
  end

  def write(session_id, projects_dir, data, env: ENV)
    mask = File.umask(0o077)
    SessionMarkers.write(session_id, projects_dir, SUFFIX, JSON.generate(data), env: env)
  ensure
    File.umask(mask) if mask
  end

  def clear(session_id, projects_dir, env: ENV)
    SessionMarkers.delete(session_id, projects_dir, SUFFIX, env: env)
  end

  # The live admin token the harness session holds, or nil.
  def token_for(session_id, projects_dir, now: Time.now)
    data = read(session_id, projects_dir)
    data && !data["token"].to_s.empty? && before?(data["expires_at"], now, REFRESH_MARGIN) ? data["token"] : nil
  end

  # The held request for `soul` while its window is open, or nil.
  def open_request(data, soul, now: Time.now)
    return nil unless data && data["soul"] == soul && data["token"].to_s.empty?
    return nil if data["request"].to_s.empty? || data["collect_key"].to_s.empty?

    before?(data["ends_at"], now, 0) ? data : nil
  end

  # Seconds to keep collecting: 0 (one attempt) to MAX_WAIT.
  def wait_seconds(value)
    Integer(value.to_s, 10, exception: false).to_i.clamp(0, MAX_WAIT)
  end

  def before?(stamp, now, margin)
    Time.parse(stamp.to_s) - margin > now
  rescue ArgumentError, TypeError
    false
  end
end
