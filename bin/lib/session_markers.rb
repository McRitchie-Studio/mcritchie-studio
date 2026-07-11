# frozen_string_literal: true

require "json"

# SessionMarkers — the marker READS that bin/atomic-event and
# bin/atomic-capture-hook used to carry byte-for-byte copies of. Both scripts
# resolve the same two markers to attribute telemetry: the worktree's
# .agent-context.json (walked up from the tool's cwd) and the per-session JSON
# marker bin/task writes under <projects>/.agents/sessions/.
#
# READ-ONLY and best-effort by contract: every failure degrades to nil so
# telemetry can never break the session. bin/agent-marker is NOT a consumer —
# it OWNS/writes the session marker under a different contract; leave it alone.
#
# NOT shared here: read_open_activity — the two scripts genuinely drift (the
# hook falls back to the legacy .open-span marker and coerces to a positive
# Integer; atomic-event reads only .open-activity and returns the String id).
module SessionMarkers
  module_function

  # Walk up from the tool's cwd to the nearest .agent-context.json.
  # nil when cwd is blank, no marker exists, or the file is unreadable/invalid.
  def read_context_marker(cwd)
    dir = cwd.to_s.strip.empty? ? nil : File.expand_path(cwd)
    return nil unless dir

    loop do
      path = File.join(dir, ".agent-context.json")
      return JSON.parse(File.read(path)) if File.file?(path)

      parent = File.dirname(dir)
      return nil if parent == dir

      dir = parent
    end
  rescue StandardError
    nil
  end

  # The per-session marker (<projects>/.agents/sessions/<id>.json) keyed by the
  # Claude/Codex session id. nil when the id is blank or the marker is
  # absent/unreadable/invalid.
  def read_session_marker(session_id, projects_dir)
    sid = session_id.to_s.strip
    return nil if sid.empty?

    safe = sid.gsub(/[^A-Za-z0-9._-]/, "")
    path = File.join(projects_dir, ".agents", "sessions", "#{safe}.json")
    return nil unless File.file?(path)

    JSON.parse(File.read(path))
  rescue StandardError
    nil
  end
end
