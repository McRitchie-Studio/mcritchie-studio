# frozen_string_literal: true

require "json"
require "socket"
require "time"
require "fileutils"
require_relative "projects_root"
require_relative "../../lib/task_usage_sandbox"

# HarnessKey: this machine's harness key (docs/agents/system/agent-sessions-design.md,
# section 3). The operator grants one per machine (`bin/harness-key request`, then
# the Approve tap or the one-time code); it mints studio logins at a task claim and
# a review claim, and reaches no other endpoint. One file under the projects
# root's `.agents/`, owner-only. The key is a bearer credential: it lives in the
# file, never on stdout.
#
# A machine with no key mints with the shared secret's token, as before.
module HarnessKey
  FILE = "harness-key.json"
  MODE = 0o600
  STORE = "harness-key"
  LABEL = /[^A-Za-z0-9 ._-]/

  module_function

  def projects_dir(env = ENV)
    dir = env["CLAUDE_PROJECTS_DIR"].to_s.strip
    dir.empty? ? ProjectsRoot.default_projects_dir : File.expand_path(dir)
  end

  # Where the key is kept, for a message: never a path a caller can act on.
  WHERE = "#{FILE} in the projects root's agent state directory"

  # A sandboxed process (a test run) never reads the operator's real key: it
  # would present it to whatever board the test points at.
  def read(projects_dir, env: ENV)
    file = path(projects_dir)
    return nil unless File.file?(file)
    return nil if TaskUsageSandbox.violation(file, store: STORE, env: TaskUsageSandbox.guard_env(env))

    data = JSON.parse(File.read(file))
    data.is_a?(Hash) ? data : nil
  rescue StandardError
    nil
  end

  # The granted key, or nil when the machine holds none.
  def token(projects_dir, env: ENV)
    value = (read(projects_dir, env: env) || {})["token"].to_s.strip
    value.empty? ? nil : value
  end

  # The request this machine posted and has not collected, while its window is open.
  def open_request(projects_dir, now: Time.now, env: ENV)
    data = read(projects_dir, env: env)
    return nil unless data && data["token"].to_s.empty?
    return nil if data["request"].to_s.empty? || data["collect_key"].to_s.empty?

    Time.parse(data["ends_at"].to_s) > now ? data : nil
  rescue ArgumentError, TypeError
    nil
  end

  def write(projects_dir, data, env: ENV)
    file = guarded_path(projects_dir, env)
    FileUtils.mkdir_p(File.dirname(file))
    File.write(file, JSON.pretty_generate(data), perm: MODE)
    File.chmod(MODE, file)
    file
  end

  def clear(projects_dir, env: ENV)
    file = guarded_path(projects_dir, env)
    File.delete(file) if File.file?(file)
  rescue Errno::ENOENT
    nil
  end

  # The name the operator reads on the request and the key: this machine's.
  def machine_label
    label = Socket.gethostname.to_s.sub(/\.local\z/, "").gsub(LABEL, "-")[0, 63].to_s
    label.match?(/\A[A-Za-z0-9]/) ? label : "machine"
  rescue StandardError
    "machine"
  end

  # Run one login mint with the machine credential. The block makes the request
  # with the bearer it is handed: the machine's harness key `key` when it holds
  # one, and the shared token (`fallback`, called only when needed) when it holds
  # none or the board answers the key 401 (revoked) or not at all. `refused` is
  # told about a key that was not accepted. Returns the last response.
  def mint(key, fallback:, refused: nil)
    if key
      res = yield(key)
      return res unless res.nil? || res.code.to_i == 401

      refused&.call(res)
    end
    token = fallback.call
    token && yield(token)
  end

  # The file's path, resolved for a mutation: a sandboxed process that cannot
  # prove its destination aborts here.
  def guarded_path(projects_dir, env)
    TaskUsageSandbox.enforce!(path(projects_dir), store: STORE, env: TaskUsageSandbox.guard_env(env))
  end

  # The raw path. Private: a caller gets the contents (read) or a guarded path
  # (write, clear), never this.
  def path(projects_dir)
    File.join(projects_dir, ".agents", FILE)
  end
  private_class_method :path
end
