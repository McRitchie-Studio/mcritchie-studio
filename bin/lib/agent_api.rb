# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "time"
require "fileutils"
require_relative "projects_root"

# AgentApi — the ONE agent-API client behind the narration/insights bin stack
# (bin/agent-activity, bin/atomic-capture-hook, bin/session-insights). Each of
# those used to RE-IMPLEMENT the same boilerplate: mint the 24h agent token
# (POST /api/v1/auth { secret }), cache it on disk at
# <projects>/.agents/atomic-capture/token.json (ONE cache shared across the
# whole stack, so `op read` runs at most ~once/day, never per call), source the
# secret (AGENT_API_SECRET env → 1Password `op read` → the repo .env), and speak
# bearer-authed JSON to ATOMIC_CAPTURE_URL (default https://mcritchie.studio).
# This class is that boilerplate, extracted verbatim.
#
# PARAMETERIZED only where the scripts genuinely diverge: the HTTP timeouts (the
# PostToolUse hook fires on EVERY tool call so it must fail in ~1-2s; the
# narration CLI and the SessionStart hook afford a little more). Everything the
# scripts agreed on — cache path, refresh margin, secret order, base_url —
# stays shared and unparameterized. The 401 policy stays with the CALLER: the
# client only EXPOSES invalidate_token! (bin/agent-activity and the capture hook
# invalidate on a 401; bin/session-insights deliberately never does).
#
# Same error posture as the scripts it serves: BEST-EFFORT, never raises —
# every failure degrades to nil, so telemetry can never break the session.
class AgentApi
  # Presence — the tiny nil/false/blank helpers every AgentApi-consuming script
  # (bin/atomic-event, bin/atomic-capture-hook, bin/session-insights) used to
  # repeat as private methods delegating to @api.present?. Include in the
  # script's class; AgentApi itself includes it too (re-exposing present? as its
  # public helper), so the logic lives exactly once.
  module Presence
    private

    def present?(value)
      !value.nil? && value != false && !value.to_s.strip.empty?
    end

    def blank_to_nil(value)
      present?(value) ? value : nil
    end

    def first_present(hash, *keys)
      keys.each do |key|
        value = hash[key]
        return value if present?(value)
      end
      nil
    end
  end

  include Presence
  public :present?

  OP = "/opt/homebrew/bin/op"
  SECRET_REF = "op://agents/Agent API Secret/AGENT_API_SECRET"
  # Reuse a cached token until this margin (seconds) before its 24h expiry.
  TOKEN_REFRESH_MARGIN = 300

  # The repo this script stack ships in (bin/lib/ → two levels up) — the CONFIG
  # anchor for the .env secret fallback. A worktree ships its own bin/, so this
  # resolves to the worktree root there, exactly as the inlined versions did
  # (each anchored one level up from bin/).
  REPO_ROOT = File.expand_path("../..", __dir__)

  attr_reader :open_timeout, :read_timeout

  def initialize(open_timeout:, read_timeout:, env: ENV)
    @env = env
    @open_timeout = open_timeout
    @read_timeout = read_timeout
  end

  # ── Base URL ───────────────────────────────────────────────────────────────

  # Activities, actions and insights MUST land on the same server for the
  # server-side activity attribution to work — so the whole stack shares this one
  # ATOMIC_CAPTURE_URL resolution.
  def base_url
    url = @env["ATOMIC_CAPTURE_URL"].to_s.strip
    url.empty? ? "https://mcritchie.studio" : url
  end

  # ── Token: mint once, cache to disk under the 24h expiry ──────────────────

  # The bearer token — the unexpired disk cache when present, else minted via
  # POST /api/v1/auth and written back to the cache. nil on any failure.
  def token
    cached = read_cached_token
    return cached if cached

    secret = agent_secret
    return nil unless secret

    res = http_json(:post, "/api/v1/auth", { "secret" => secret }, bearer: nil)
    return nil unless res && res.code.to_i.between?(200, 299)

    body = JSON.parse(res.body) rescue {}
    tok = body["token"]
    write_cached_token(tok, body["expires_at"]) if present?(tok)
    tok
  rescue StandardError
    nil
  end

  # Drop the cached token (the caller's 401 policy) so the next call re-mints.
  def invalidate_token!
    File.delete(token_cache_path)
  rescue StandardError
    nil
  end

  # ── HTTP (bounded timeouts, nil on any failure) ────────────────────────────

  def http_get(path, bearer:)
    http_request(Net::HTTP::Get, path, nil, bearer: bearer)
  end

  def http_json(method, path, body, bearer:)
    klass = { get: Net::HTTP::Get, post: Net::HTTP::Post }.fetch(method)
    http_request(klass, path, body, bearer: bearer)
  end

  # ── Paths + tiny helpers (the scripts' own marker reads share these) ───────

  def projects_dir
    dir = @env["CLAUDE_PROJECTS_DIR"].to_s.strip
    dir.empty? ? default_projects_dir : File.expand_path(dir)
  end

  private

  def token_cache_path
    File.join(projects_dir, ".agents", "atomic-capture", "token.json")
  end

  def read_cached_token
    path = token_cache_path
    return nil unless File.file?(path)

    data = JSON.parse(File.read(path))
    return nil unless present?(data["token"])

    if present?(data["expires_at"])
      expires = Time.parse(data["expires_at"])
      return nil if Time.now >= (expires - TOKEN_REFRESH_MARGIN)
    end
    data["token"]
  rescue StandardError
    nil
  end

  def write_cached_token(tok, expires_at)
    path = token_cache_path
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate("token" => tok, "expires_at" => expires_at))
  rescue StandardError
    nil
  end

  # ENV, then 1Password, then repo .env — the same order as bin/task.
  def agent_secret
    env = @env["AGENT_API_SECRET"].to_s
    return env unless env.empty?

    if File.executable?(OP)
      op = begin
        IO.popen([OP, "read", SECRET_REF], err: File::NULL, &:read).to_s.strip
      rescue StandardError
        ""
      end
      return op unless op.empty?
    end

    dotenv = File.join(REPO_ROOT, ".env")
    if File.file?(dotenv)
      line = File.readlines(dotenv).find { |l| l.start_with?("AGENT_API_SECRET=") }
      return line.split("=", 2)[1].to_s.strip if line
    end
    nil
  rescue StandardError
    nil
  end

  def http_request(klass, path, body, bearer:)
    uri = URI.join(base_url, path)
    req = klass.new(uri)
    req["Authorization"] = "Bearer #{bearer}" if bearer
    if body
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(body)
    end
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = @open_timeout
    http.read_timeout = @read_timeout
    http.request(req)
  rescue StandardError
    nil
  end

  # The projects root when CLAUDE_PROJECTS_DIR is unset — see ProjectsRoot.
  def default_projects_dir
    ProjectsRoot.default_projects_dir(REPO_ROOT)
  end
end
