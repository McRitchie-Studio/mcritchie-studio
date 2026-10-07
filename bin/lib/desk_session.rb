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
# `bin/task` write to THAT task, run from inside THAT desk, presents the session
# token instead of the shared secret's, so the board stamps the actor from the
# session. Every other call (a read, another task, a script run from any other
# tree) keeps the shared token, so a reviewer on the same laptop never borrows the
# builder's login.
#
# The token is a bearer credential: it lives in the file, never on stdout.
module DeskSession
  FILE = "agent-session.json"
  MODE = 0o600
  # Stop using a token this many seconds before its session expires.
  REFRESH_MARGIN = 60
  TASK_WRITE = %r{\A/api/v1/tasks/([^/?]+)}

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

  # The session token for a write to `slug` from the desk at `root`, or nil when
  # the desk holds no live login for that task.
  def token_for(slug, root:, now: Time.now)
    return nil if slug.to_s.empty?

    data = read(root)
    return nil unless data && data["task_slug"] == slug && !data["token"].to_s.empty?

    expires = Time.parse(data["expires_at"].to_s)
    expires - REFRESH_MARGIN > now ? data["token"] : nil
  rescue ArgumentError, TypeError
    nil
  end
end
