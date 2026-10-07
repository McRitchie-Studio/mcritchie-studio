# frozen_string_literal: true

require "json"
require "time"
require "fileutils"

# DeskSession: the studio login a desk holds (docs/agents/system/agent-sessions-design.md).
#
# `bin/task begin` logs the desk's soul in to the task it claimed
# (POST /api/v1/agent_sessions) and writes the session token to
# `agent-session.json` inside the desk's own git directory (a worktree's `.git`
# file points at it), owner-only. Inside the git directory it can never be
# committed, in any repo, and no other worktree reads it. From then on a
# `bin/task` write to THAT task, run from inside THAT desk BY THE HARNESS SESSION
# THAT OPENED IT, presents the session token instead of the shared secret's, so the
# board stamps the actor from the session. Every other call (a read, another task,
# a script run from any other tree, or a different harness session acting from
# inside this desk, such as a reviewer) keeps the shared token, so a reviewer never
# borrows the builder's login, even from the builder's own desk.
#
# The owner is the harness session id (SessionIdentity: CLAUDE_CODE_SESSION_ID or
# CODEX_THREAD_ID) recorded at the login. A file that names none, or a run that
# names none, cannot prove it is the owner, so it keeps the shared token.
#
# When the board refuses the session, the desk drops it: the token is erased and
# the file keeps only the session's slug, marked dropped. From then on the owner's
# writes to that task (and its writes after the session expires) send the slug in
# DROPPED_HEADER, so the board's legacy-token log line names the desk's session
# instead of reading as an anonymous shared-token call.
#
# The token is a bearer credential: it lives in the file, never on stdout.
module DeskSession
  FILE = "agent-session.json"
  MODE = 0o600
  # Stop using a token this many seconds before its session expires.
  REFRESH_MARGIN = 60
  TASK_WRITE = %r{\A/api/v1/tasks/([^/?]+)}
  # The request header naming the desk's dropped (or expired) session slug on a
  # shared-token fallback. Read by Api::V1::BaseController#authenticate_legacy_token!.
  DROPPED_HEADER = "X-Agent-Session-Dropped"

  module_function

  # The task slug a request writes, or nil when it is a read or names no task.
  def task_slug_for(method, path)
    return nil if method.to_s == "get"

    slug = path.to_s[TASK_WRITE, 1]
    slug == "claim_next_review" ? nil : slug
  end

  # The desk root that holds `start`: the nearest ancestor carrying a `.git`
  # entry (a worktree's `.git` is a file). nil outside any checkout.
  def root_for(start = Dir.pwd)
    dir = File.expand_path(start)
    loop do
      return dir if File.exist?(File.join(dir, ".git"))

      parent = File.dirname(dir)
      return nil if parent == dir

      dir = parent
    end
  end

  # The session file for the desk at `root`: inside its git directory. A worktree's
  # `.git` is a file reading `gitdir: <path>`; a plain checkout's is the directory.
  def path(root)
    dot_git = File.join(root, ".git")
    git_dir = if File.file?(dot_git)
                pointer = File.read(dot_git)[/\Agitdir:\s*(.+)$/, 1].to_s.strip
                File.expand_path(pointer, root)
              else
                dot_git
              end
    File.join(git_dir, FILE)
  end

  def read(root)
    return nil if root.nil?

    file = path(root)
    return nil unless File.file?(file)

    data = JSON.parse(File.read(file))
    data.is_a?(Hash) ? data : nil
  rescue StandardError
    nil
  end

  def write(root, session)
    file = path(root)
    FileUtils.mkdir_p(File.dirname(file))
    File.write(file, JSON.pretty_generate(session), perm: MODE)
    File.chmod(MODE, file)
    file
  end

  def clear(root)
    File.delete(path(root)) if root && File.file?(path(root))
  rescue StandardError
    nil
  end

  # Drop the desk's session after the board refused it: erase the token and keep
  # the slug, so later fallback writes can still name it. Never raises.
  def drop(root, now: Time.now)
    data = read(root)
    return clear(root) unless data

    write(root, data.except("token").merge("dropped_at" => now.utc.iso8601))
  rescue StandardError
    clear(root)
  end

  # The desk's session for a write to `slug` by the harness session
  # `harness_session_id`, or nil when the desk holds none for that task or the
  # caller is not the harness that opened it.
  def owned_session(slug, root:, harness_session_id:)
    return nil if slug.to_s.empty? || harness_session_id.to_s.strip.empty?

    data = read(root)
    return nil unless data && data["task_slug"] == slug
    return nil unless data["harness_session_id"].to_s == harness_session_id.to_s.strip

    data
  end

  # The session token for a write to `slug` from the desk at `root`, or nil when
  # the desk holds no live login for that task or the caller is another harness.
  def token_for(slug, root:, harness_session_id:, now: Time.now)
    data = owned_session(slug, root: root, harness_session_id: harness_session_id)
    return nil unless data && !data["token"].to_s.empty?

    live?(data, now) ? data["token"] : nil
  end

  # The slug of the owner's session for `slug` when that session no longer
  # answers (dropped or expired), so a fallback write can name it; nil otherwise.
  def dropped_slug_for(slug, root:, harness_session_id:, now: Time.now)
    data = owned_session(slug, root: root, harness_session_id: harness_session_id)
    return nil unless data && !data["slug"].to_s.empty?
    return nil if !data["token"].to_s.empty? && live?(data, now)

    data["slug"]
  end

  def live?(data, now)
    Time.parse(data["expires_at"].to_s) - REFRESH_MARGIN > now
  rescue ArgumentError, TypeError
    false
  end
end
