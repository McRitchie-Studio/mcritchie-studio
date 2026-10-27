# frozen_string_literal: true

require "json"
require "socket"
require "time"
require "fileutils"
require_relative "projects_root"
require_relative "../../lib/task_usage_sandbox"
require_relative "secret_cache"

# HarnessKey: this machine's harness key (docs/agents/system/agent-sessions-design.md,
# section 3). The operator grants one per machine (`bin/harness-key request`, then
# the Approve tap or the one-time code). It mints studio logins at a task claim and
# a review claim, reads the board, narrates, creates a task and makes its claim
# (DOORS); it writes no other task. One owner-only file in the secret cache,
# <projects>/.secret-cache/harness-key.json (bin/lib/secret_cache.rb). The key is a
# bearer credential: it lives in the file, never on stdout.
#
# THE LEGACY PATH (2026-10-27). It lived at <projects>/.agents/harness-key.json. A
# read takes the folder's file, else the legacy one; the first write moves the
# legacy file into the folder and leaves a symlink, so an older reader still finds
# the key; a clear removes both.
#
# A machine with no key presents the shared secret's token, as before.
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
  WHERE = "#{FILE} in the projects root's secret cache (#{SecretCache::DIR_NAME})"

  # A sandboxed process (a test run) never reads the operator's real key: it
  # would present it to whatever board the test points at.
  def read(projects_dir, env: ENV)
    cache_env = cache_env(projects_dir, env)
    file = File.join(SecretCache.dir(cache_env), FILE)
    if File.file?(file)
      SecretCache.check_safe!(cache_env)
      SecretCache.check_file!(file)
    else
      file = path(projects_dir)
    end
    return nil unless File.file?(file)
    return nil if TaskUsageSandbox.violation(file, store: STORE, env: TaskUsageSandbox.guard_env(env))

    data = JSON.parse(File.read(file))
    data.is_a?(Hash) ? data : nil
  rescue SecretCache::Unsafe => e
    # Loud, and still no key: an unsafe folder is never read, and the caller falls
    # back to the shared token exactly as for a machine with no key.
    warn("harness-key: #{e.message}")
    nil
  rescue StandardError
    nil
  end

  # The env the secret cache resolves against: this projects dir, unless the
  # caller pinned the cache folder itself.
  def cache_env(projects_dir, env)
    env.to_h.merge("CLAUDE_PROJECTS_DIR" => projects_dir.to_s)
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
    legacy = guarded_path(projects_dir, env)
    cache_env = cache_env(projects_dir, env)
    SecretCache.adopt_legacy!(legacy, FILE, env: cache_env)
    file = SecretCache.write_json(FILE, data, env: cache_env)
    SecretCache.adopt_legacy!(legacy, FILE, env: cache_env, relink: true)
    file
  end

  def clear(projects_dir, env: ENV)
    legacy = guarded_path(projects_dir, env)
    SecretCache.delete(FILE, env: cache_env(projects_dir, env))
    File.delete(legacy) if File.file?(legacy) || File.symlink?(legacy)
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

  # The requests the board accepts a harness key on, as [method, path pattern,
  # body rule]: the mint doors, the board's reads, narration, a task's create and
  # its claim. The board's own list is Api::V1::BaseController.accepts_harness_key;
  # test/integration/harness_key_client_doors_test.rb pins this one to it.
  DOORS = [
    [:get, %r{\A/api/v1/tasks\z}],
    [:get, %r{\A/api/v1/tasks/[^/]+\z}],
    [:get, %r{\A/api/v1/tasks/[^/]+/(?:building_lane|review_claim)\z}],
    [:get, %r{\A/api/v1/(?:activities|review_pending_actions|devops_shifts|desk_records|agents|insights)\z}],
    [:get, %r{\A/api/v1/agents/[^/]+\z}],
    [:get, %r{\A/api/v1/gates/[^/]+/[^/]+\z}],
    [:get, %r{\A/api/v1/release_conductor_claims/live\z}],
    [:get, %r{\A/api/v1/releases/[^/]+/conductor_claim\z}],
    [:get, %r{\A/api/v1/agent_activities/(?:windows|awaiting_grade)\z}],
    [:get, %r{\A/api/v1/agent_sessions/current\z}],
    [:post, %r{\A/api/v1/agent_activities(?:/(?:close|close_all|turn_open|reconcile))?\z}],
    [:post, %r{\A/api/v1/agent_actions\z}],
    [:post, %r{\A/api/v1/tasks\z}, :create],
    [:post, %r{\A/api/v1/agent_sessions\z}],
    [:post, %r{\A/api/v1/tasks/[^/]+/review_claim\z}],
    [:post, %r{\A/api/v1/tasks/claim_next_review\z}],
    [:post, %r{\A/api/v1/agent_login_requests(?:/[^/]+/(?:code|collect))?\z}],
    [:patch, %r{\A/api/v1/tasks/[^/]+\z}, :claim]
  ].freeze
  # The fields a claim carries (Api::V1::TasksController::HARNESS_CLAIM_FIELDS).
  CLAIM_FIELDS = %w[stage event devops dev_size].freeze

  # Does the board take a harness key on this request? `body` is the JSON body the
  # caller will send, for the two doors that are one case of a wider action: a
  # task's create (in designed) and its claim (a move to building that carries
  # only CLAIM_FIELDS).
  def accepts?(method, request_path, body = nil)
    route = request_path.to_s.split("?", 2).first.to_s
    DOORS.any? do |verb, pattern, rule|
      verb == method.to_s.downcase.to_sym && pattern.match?(route) && body_passes?(rule, body)
    end
  end

  def body_passes?(rule, body)
    fields = body.is_a?(Hash) ? body.transform_keys(&:to_s) : {}
    case rule
    when :create then [ "", "designed" ].include?(fields["stage"].to_s)
    when :claim then fields["stage"].to_s == "building" && (fields.keys - CLAIM_FIELDS).empty?
    else true
    end
  end
  private_class_method :body_passes?

  # Should a call made with the key be made again with the shared token? When
  # the board did not answer, answered the key 401 (revoked or unknown), or
  # answered it 403 SESSION_FORBIDDEN: a board that predates a door refuses the
  # key there, and the shared token is still accepted wherever it was.
  def fall_back?(res)
    return true if res.nil?

    code = res.code.to_i
    return true if code == 401
    return false unless code == 403

    (JSON.parse(res.body.to_s)["error_code"] rescue nil) == "SESSION_FORBIDDEN"
  end

  # Run one call at a door the key opens (DOORS). The block makes the request with
  # the bearer it is handed: the key when the machine holds one, and the shared
  # token (`fallback`, called only when needed) when it holds none or fall_back?
  # says so. `refused` is told about a key that was not accepted.
  def call(key, fallback:, refused: nil)
    if key
      res = yield(key)
      return res unless fall_back?(res)

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
