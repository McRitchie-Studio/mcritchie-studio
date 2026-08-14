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
#
# POSTURE-FREE IS NOT THE SAME AS LENIENT. `request` still takes no view on the
# status, but the BODY now has two readers and the caller picks by what it is
# about to do with the answer:
#
#   parse_body(res)  — LENIENT. `{}` on an empty or non-JSON body. For DISPLAY,
#                      for optional-field plucking, and for a legitimately empty
#                      body (204/DELETE). It cannot tell broken from empty.
#   rows!(res)       — STRICT. The board's list, or UnreadableResponse. For
#                      anything that COUNTS, tests `.empty?`, or concludes
#                      "none, therefore proceed".
#
# The split exists because leniency is defensible for rendering and indefensible
# for counting: an unreadable answer scored as zero is a FALSE NEGATIVE in a
# safety mechanism, and it always resolves toward "proceed". bin/lib/bounce_ledger.rb
# is the same posture built for one caller (the two-bounce circuit breaker); it
# had to bypass `api` entirely to get it. `rows!` is that guarantee, shared.
module TaskBoard
  OP = "/opt/homebrew/bin/op"
  SECRET_REF = "op://agents/Agent API Secret/AGENT_API_SECRET"

  # Raised by the STRICT readers (`parse_body!`, `rows!`) for every answer a
  # caller cannot trust: an empty body, a body that is not JSON, a payload that
  # is not a JSON object, a payload the board filled with an error instead of
  # rows, or a payload carrying no list where one was required.
  #
  # ONE class, because all of them mean the same thing to the caller: YOU DO NOT
  # KNOW. A count you could not READ is never a count of zero.
  class UnreadableResponse < StandardError; end

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

  # LENIENT body parse: {} on an empty or non-JSON body — the die!-family
  # scripts parse this way so a non-JSON error page still renders a verdict, and
  # so a 204/DELETE with no body at all reads as "nothing to say" rather than an
  # error. That posture is correct for DISPLAY and for optional-field plucking.
  #
  # ⛔ NEVER COUNT THROUGH THIS. `{}` is indistinguishable from a genuinely empty
  # answer, so `parse_body(res)["data"]` is nil, `Array(nil)` is `[]`, and the
  # count is 0 — with no exception and no warning. For a SAFETY count ("how many
  # times has this been sent back?", "are there open blockers?") empty is the
  # REASSURING answer, so a broken read resolves in the direction that lets work
  # proceed. Counting callers use `rows!`, which refuses instead of answering.
  def parse_body(res)
    res.body.to_s.empty? ? {} : (JSON.parse(res.body) rescue {})
  end

  # STRICT body parse — the same read as `parse_body`, refusing where that one
  # shrugs. Raises UnreadableResponse on an empty body, a non-JSON body, or a
  # payload that is not a JSON object. Returns the parsed Hash otherwise,
  # INCLUDING a board error payload: a caller that wants to render the error
  # still gets it, and `rows!` is the layer that refuses one.
  #
  # Status stays the CALLER's posture (see the module header) — the strict
  # readers never check `res.code`, they only refuse a body they cannot read.
  # They do not need to: a non-2xx from this board either carries an error
  # payload (refused by `rows!`), an HTML error page (refused here as non-JSON),
  # or no body at all (refused here as empty).
  def parse_body!(res)
    raise UnreadableResponse, "expected an HTTP response, got #{res.class}" unless res.respond_to?(:body)

    text = res.body.to_s
    raise UnreadableResponse, "the board returned an EMPTY body#{status_suffix(res)}" if text.strip.empty?

    parsed = begin
      JSON.parse(text)
    rescue JSON::ParserError => e
      raise UnreadableResponse,
            "the board returned a body that is not JSON#{status_suffix(res)} " \
            "(#{e.message.split("\n").first}). A lenient parse would score this an " \
            "EMPTY answer; it is an unreadable one."
    end

    unless parsed.is_a?(Hash)
      raise UnreadableResponse, "expected a JSON object from the board, got #{parsed.class}"
    end

    parsed
  end

  # STRICT ROW READER — the entry point for every caller that COUNTS, and the
  # whole reason UnreadableResponse exists. Returns the payload's list under
  # `key`, or raises. The shape check is the load-bearing half: an unauthorized
  # or errored read has no `data` array either, and scoring THAT zero is how a
  # safety count gets silently disarmed by an expired token.
  #
  # A list endpoint that succeeded ALWAYS carries its array, even when empty —
  # so `[]` from here means genuinely none, which is exactly the distinction
  # `parse_body` cannot make.
  #
  # TAKES EITHER a Net::HTTPResponse or an ALREADY-PARSED payload, deliberately:
  # you hand it the thing you actually have. The die!-family wrappers (bin/task,
  # bin/dor-check, bin/triage, bin/reviewer-select) all parse LENIENTLY first and
  # feed that parse to their non-2xx error line (`parsed["error"] || res.body`),
  # because the body there is routinely an HTML error page. Forcing them to hand
  # over a response instead would replace those rendered verdicts with a parser
  # backtrace — a worse bug than the one this reader exists to fix. So they keep
  # their lenient parse for the ERROR RENDER and pass the payload here for the
  # COUNT, and the accident of handing a response to a payload-shaped method
  # (the very mistake bin/lib/bounce_ledger.rb was written to name) cannot happen.
  def rows!(res_or_payload, key: "data")
    res = res_or_payload.respond_to?(:body) ? res_or_payload : nil
    payload = res ? parse_body!(res) : res_or_payload

    unless payload.is_a?(Hash)
      raise UnreadableResponse,
            "expected an HTTP response or a parsed JSON object, got #{payload.class}"
    end

    if payload["error"] || payload["error_code"]
      raise UnreadableResponse,
            "the board returned an error, not #{key}#{status_suffix(res)}: " \
            "#{payload["error_code"] || "ERROR"} #{payload["error"]}".strip
    end

    list = payload[key]
    unless list.is_a?(Array)
      keys = payload.keys.empty? ? "none" : payload.keys.join(", ")
      raise UnreadableResponse,
            "the payload carries no `#{key}` array (keys: #{keys})#{status_suffix(res)}. " \
            "A read that succeeded ALWAYS has one, even when empty — so this is an " \
            "unreadable answer, NOT an empty one."
    end

    list
  end

  # " [HTTP 401]" when the response knows its status, "" otherwise. The code is
  # the first thing a reader wants and the last thing a bare parse error shows.
  def status_suffix(res)
    return "" unless res.respond_to?(:code)

    code = res.code.to_s
    code.empty? ? "" : " [HTTP #{code}]"
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
