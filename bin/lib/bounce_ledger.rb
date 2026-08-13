# frozen_string_literal: true

require "json"
require "net/http"

# BounceLedger — the TWO-BOUNCE CIRCUIT BREAKER's read, as code instead of prose.
#
# THE BUG THIS FILE EXISTS TO KILL (found 2026-08-13, primary review of
# /tasks/lease-outlives-idle-session). The review SOPs used to hand an agent a
# bare recipe — "GET /api/v1/activities?task_slug=<t>&activity_type=qa_feedback,
# count the rows" — and every agent hand-rolled the HTTP. The hand-rolled form is
# a TRAP, and not a subtle one:
#
#   res = TaskBoard.request(:get, "/api/v1/activities?...", token: token)
#   Array(res["data"]).size   # => 0. ALWAYS 0. For every task, forever.
#
# `res` is a Net::HTTPResponse, and Net::HTTPResponse#[] is the HTTP **HEADER**
# reader (Net::HTTPHeader#[]), not a Hash lookup. There is no `data` header, so
# it returns nil, `Array(nil)` is `[]`, and the count is 0 — with no exception,
# no warning, and an answer that looks exactly like the good news the caller was
# hoping for. The response has to be PARSED (`JSON.parse(res.body)`) first.
#
# WHY IT IS A SAFETY DEFECT AND NOT A TYPO. The two-bounce breaker is the thing
# that converts a repeatedly-bounced task into an ESCALATION to the operator. A
# silent always-zero means a task can bounce forever and never escalate: the
# builder keeps getting sent back, and nobody is ever told. That is a FALSE
# NEGATIVE in a safety mechanism — the worst shape a defect can take, because
# the mechanism looks like it is working.
#
# THE THREE WAYS THE COUNT IS KNOWN TO GO WRONG, all of which this module
# refuses instead of answering:
#
#   1. UNPARSED RESPONSE — the trap above. `from_payload` raises when it is
#      handed a Net::HTTPResponse, naming the mistake.
#   2. UNAUTHENTICATED READ — a 401 (agent tokens last 24h and expire mid-shift)
#      has no `data` array either, so a lenient reader scores it 0 and the
#      breaker is silently DISARMED by an auth failure. `from_response` raises on
#      any non-2xx, and says out loud that UNKNOWN is not CLEAR.
#   3. ROW-KIND MISMATCH — not every `qa_feedback` row is a send-back to the
#      builder. `bin/task block` writes one for EVERY kind, so an `environment`
#      blocker or the escalation itself (`--kind dependency`) used to count as a
#      bounce and trip the breaker early. Rows now carry their kind in
#      `metadata["kind"]` and are classified below.
#
# THE POSTURE IS DELIBERATELY THE OPPOSITE OF bin/lib/task_board.rb. TaskBoard is
# posture-free on purpose (it returns the raw response and never rescues) because
# its five callers genuinely differ in how they fail. This module has exactly one
# job and one safe answer: a count it could not READ is never a count of zero.
module BounceLedger
  # Raised for every unreadable answer — a non-2xx, a body that is not JSON, a
  # payload with no `data` array, or the response object itself. One class, because
  # every one of them means the same thing to a caller: YOU DO NOT KNOW, and you
  # must not proceed as though the answer were zero.
  class UnreadableResponse < StandardError; end

  # The kinds `bin/task block --kind` can stamp (mirrors Task::BLOCK_KINDS), plus
  # UNKNOWN_KIND for a row that carries no kind at all.
  KINDS = %w[environment rework dependency].freeze
  UNKNOWN_KIND = "unknown"

  # WHICH ROWS ARE A BOUNCE — i.e. "review sent this task BACK TO THE BUILDER".
  #
  # `rework` is the send-back itself. `unknown` counts too, and that asymmetry is
  # the point: rows written before kinds were stamped (and any row from
  # `bin/task note --qa-feedback`) cannot be classified, and the safe reading of an
  # unclassifiable row in a SAFETY mechanism is that it might be a bounce. Missing
  # a real bounce is the failure this whole file is about; an extra escalation is
  # merely noise, and the CLI prints the rows so the reader can judge.
  #
  # `dependency` and `environment` are NOT bounces. A dependency block is the
  # ESCALATION — counting it would mean the breaker's own output re-tripped it on
  # the next read. An environment block is a blocked desk, not a review verdict.
  COUNTABLE_KINDS = [ "rework", UNKNOWN_KIND ].freeze

  # One qa_feedback row, flattened to what the breaker needs.
  Row = Struct.new(:created_at, :kind, :summary, :agent_slug, keyword_init: true) do
    def countable?
      BounceLedger::COUNTABLE_KINDS.include?(kind)
    end
  end

  # The breaker's answer. `tripped?` is the ONLY thing a caller should branch on.
  Verdict = Struct.new(:rows, keyword_init: true) do
    def countable_rows
      rows.select(&:countable?)
    end

    def count
      countable_rows.size
    end

    # The SOP's rule, verbatim: one or more prior send-backs means this block
    # would be the SECOND, and a repeat bounce is a review deadlock — the
    # operator's call, never a ping-pong.
    def tripped?
      count.positive?
    end

    def by_kind
      rows.group_by(&:kind).transform_values(&:size)
    end
  end

  module_function

  # The full path from an HTTP response to a verdict — status check, strict parse,
  # shape check. This is the entry point every caller should use, because it is the
  # one that makes the response object impossible to misread: you hand it the thing
  # you actually have.
  def from_response(response)
    from_payload(payload_from(response))
  end

  # Response → trustworthy parsed payload, or raise. Split out from `from_response`
  # so a paging caller can read `meta` off the SAME parse the verdict came from
  # rather than parsing the body twice.
  def payload_from(response)
    unless response.respond_to?(:code) && response.respond_to?(:body)
      raise UnreadableResponse, "expected an HTTP response, got #{response.class}"
    end

    code = response.code.to_i
    unless code.between?(200, 299)
      raise UnreadableResponse, unreadable_status_message(code, response.body)
    end

    strict_parse(response.body)
  end

  # The verdict from an ALREADY-PARSED payload. Kept separate so the classification
  # is unit-testable without HTTP — and so the exact defect (handing it the
  # response object) gets a message that names the mistake rather than a nil chain.
  def from_payload(payload)
    if payload.is_a?(Net::HTTPResponse)
      raise UnreadableResponse,
            "this is the Net::HTTP RESPONSE OBJECT, not its parsed body. " \
            "Net::HTTPResponse#[] reads HTTP HEADERS, so response[\"data\"] is nil and " \
            "the bounce count silently reads 0 for every task. Parse it first: " \
            "JSON.parse(response.body) — or just call BounceLedger.from_response(response)."
    end

    unless payload.is_a?(Hash)
      raise UnreadableResponse, "expected a parsed JSON object, got #{payload.class}"
    end

    if payload["error"] || payload["error_code"]
      raise UnreadableResponse,
            "the board returned an error, not activities: " \
            "#{payload["error_code"] || "ERROR"} #{payload["error"]}".strip
    end

    data = payload["data"]
    unless data.is_a?(Array)
      keys = payload.keys.empty? ? "none" : payload.keys.join(", ")
      raise UnreadableResponse,
            "the payload carries no `data` array (keys: #{keys}). " \
            "An activities read that succeeded ALWAYS has one, even when empty — " \
            "so this is an unreadable answer, NOT zero bounces."
    end

    Verdict.new(rows: data.map { |row| build_row(row) })
  end

  # Page-aware total, for a caller that already collected several pages: a
  # truncated read must never masquerade as a complete one.
  def truncated?(payload)
    meta = payload.is_a?(Hash) ? payload["meta"] : nil
    return false unless meta.is_a?(Hash)

    total = meta["total"].to_i
    total > Array(payload["data"]).size
  end

  def strict_parse(body)
    text = body.to_s
    raise UnreadableResponse, "the board returned an EMPTY body" if text.strip.empty?

    JSON.parse(text)
  rescue JSON::ParserError => e
    raise UnreadableResponse,
          "the board returned a body that is not JSON (#{e.message.split("\n").first}). " \
          "A lenient parse would score this 0 bounces; it is an unreadable answer."
  end

  def build_row(row)
    row = {} unless row.is_a?(Hash)
    metadata = row["metadata"]
    metadata = {} unless metadata.is_a?(Hash)
    kind = metadata["kind"].to_s.strip
    kind = UNKNOWN_KIND unless KINDS.include?(kind)

    Row.new(
      created_at: row["created_at"].to_s,
      kind: kind,
      summary: (metadata["summary"].to_s.strip.empty? ? first_line(row["description"]) : metadata["summary"].to_s.strip),
      agent_slug: row["agent_slug"].to_s
    )
  end

  def first_line(text)
    line = text.to_s.lines.map(&:strip).reject(&:empty?).first.to_s
    line.length > 72 ? "#{line[0, 71]}…" : line
  end

  def unreadable_status_message(code, body)
    if code == 401
      "HTTP 401 UNAUTHORIZED reading the bounce ledger. Agent tokens last 24h; this one is " \
      "expired or missing. An unauthenticated read has no rows to count, which is NOT the " \
      "same as no bounces — treating it as zero silently DISARMS the circuit breaker."
    else
      "HTTP #{code} reading the bounce ledger: #{first_line(body)}"
    end
  end
end
