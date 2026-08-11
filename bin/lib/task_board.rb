# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

# TaskBoard — the shared TRANSPORT under the task-board CLI stack (bin/task,
# bin/dor-check, bin/reviewer-select, bin/session-preflight, bin/devops-cycle).
# Each of those used to RE-IMPLEMENT the same Net::HTTP boilerplate; this module
# is that boilerplate, extracted verbatim.
#
# Deliberately POSTURE-FREE: `request` returns the raw Net::HTTPResponse without
# checking the status, and never rescues — because the five scripts genuinely
# DIFFER in how they fail (bin/task, bin/dor-check and bin/reviewer-select die!
# with "<METHOD> <path> -> <code>", reviewer-select adds a GET-404 special case,
# bin/session-preflight and bin/devops-cycle raise for their callers to rescue).
# Each script keeps its exact error rendering in its own thin `api` wrapper.
#
# Tokens stay per-process too: every CLI mints its own 24h token per run (the
# memoized `token` helper stays in each script); only the narration stack
# (bin/lib/agent_api.rb) uses the shared disk cache.
module TaskBoard
  OP = "/opt/homebrew/bin/op"
  SECRET_REF = "op://agents/Agent API Secret/AGENT_API_SECRET"

  module_function

  # Perform one JSON request. `path_or_uri` is a path joined onto `base_url`, or
  # a prebuilt URI (bin/devops-cycle builds its own to carry query strings).
  # `read_timeout: nil` leaves Net::HTTP's default (devops-cycle's posture).
  def request(method, path_or_uri, base_url: nil, token: nil, body: nil, read_timeout: 30)
    uri = path_or_uri.is_a?(URI::Generic) ? path_or_uri : URI.join(base_url, path_or_uri)
    klass = { get: Net::HTTP::Get, post: Net::HTTP::Post, patch: Net::HTTP::Patch,
              delete: Net::HTTP::Delete }.fetch(method)
    req = klass.new(uri)
    req["Authorization"] = "Bearer #{token}" if token
    if body
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(body)
    end
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.read_timeout = read_timeout if read_timeout
    http.request(req)
  end

  # Lenient body parse: {} on an empty or non-JSON body — the die!-family
  # scripts parse this way so a non-JSON error page still renders a verdict.
  def parse_body(res)
    res.body.to_s.empty? ? {} : (JSON.parse(res.body) rescue {})
  end

  # The agent secret: ENV, then 1Password, then the given .env file — the same
  # order every task-board CLI used inline. Returns nil when not found so each
  # caller keeps its own missing-secret posture (die! vs degrade to "").
  # NOTE: bin/devops-cycle keeps its OWN chain — it deliberately SKIPS 1Password
  # and strips quotes from .env values; do not fold it into this method.
  def agent_secret(dotenv)
    env = ENV["AGENT_API_SECRET"]
    return env if env && !env.empty?

    if File.executable?(OP)
      op = begin
        IO.popen([OP, "read", SECRET_REF], err: File::NULL, &:read).to_s.strip
      rescue SystemCallError
        ""
      end
      return op unless op.empty?
    end

    if File.exist?(dotenv)
      line = File.readlines(dotenv).find { |l| l.start_with?("AGENT_API_SECRET=") }
      return line.split("=", 2)[1].to_s.strip if line
    end
    nil
  end
end
