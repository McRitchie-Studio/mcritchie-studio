# frozen_string_literal: true

require "json"

# Reads a Claude Code session transcript and turns it into per-transition usage
# for the task-board event trail — so `bin/task move` can auto-stamp the model,
# token delta, and cost the agent burned, with the agent passing no flags.
#
# The transcript lives at ~/.claude/projects/<project-dir>/<session-id>.jsonl;
# bin/task already knows the session id (CLAUDE_CODE_SESSION_ID). Each assistant
# line carries `message.model` and a `message.usage` block. Each API request is
# billed independently, so SUMMING usage across assistant lines is the session's
# cumulative billed tokens; the delta between two moves is the work done in the
# stage being left.
#
# Plain Ruby (no Rails) so bin/task can require it directly. Best-effort by
# design: a missing/unreadable transcript or a non-Claude session yields nil, and
# the caller falls back to recording only the deterministic spine.
class AgentSessionUsage
  # Per-million-token rates (input, output). Source: claude-api skill reference
  # (cached 2026-06-04). Cache-write (5m TTL) is 1.25x input and cache-read is
  # 0.10x input, so we store only input/output and derive the cache rates.
  PRICING = {
    "claude-opus-4-8"   => { input: 5.0,  output: 25.0 },
    "claude-opus-4-7"   => { input: 5.0,  output: 25.0 },
    "claude-opus-4-6"   => { input: 5.0,  output: 25.0 },
    "claude-sonnet-4-6" => { input: 3.0,  output: 15.0 },
    "claude-haiku-4-5"  => { input: 1.0,  output: 5.0 },
    "claude-fable-5"    => { input: 10.0, output: 50.0 }
  }.freeze
  CACHE_WRITE_MULTIPLIER = 1.25 # 5-minute TTL
  CACHE_READ_MULTIPLIER  = 0.10
  BUCKETS = %w[input output cache_creation cache_read].freeze

  # The capture result. `totals` is the session's cumulative usage now (becomes
  # the next baseline); `delta` is the usage since the prior baseline (nil on the
  # first move, when there is no baseline yet).
  Result = Struct.new(:model, :totals, :delta, keyword_init: true) do
    # True only when there's a measured delta with real tokens to report.
    def usage?
      !delta.nil? && BUCKETS.any? { |b| delta[b].to_i.positive? }
    end

    # Input-side tokens of the delta (new input + cache writes + cache reads).
    def tokens_in
      delta["input"].to_i + delta["cache_creation"].to_i + delta["cache_read"].to_i
    end

    def tokens_out
      delta["output"].to_i
    end

    # Dollar cost of the delta, or nil for an unknown model (tokens still record).
    def cost
      AgentSessionUsage.price(delta, model)
    end
  end

  # Build a Result for the session, or nil when there's no readable transcript
  # (no session id, file absent, or unparseable) — the caller records spine-only.
  def self.capture(session_id:, baseline: nil, transcript_root: default_root)
    path = transcript_for(session_id, transcript_root)
    return nil unless path

    totals, model = sum_usage(path)
    return nil if totals.nil?

    Result.new(model: model, totals: totals, delta: baseline && bucket_delta(totals, baseline))
  end

  def self.default_root
    File.join(Dir.home, ".claude", "projects")
  end

  # Glob the transcript by session id across project dirs (the dir is the launch
  # cwd, which differs in a worktree, so we don't reconstruct it — the id is
  # unique). Returns the path or nil.
  def self.transcript_for(session_id, root)
    id = session_id.to_s.strip
    return nil if id.empty?

    Dir.glob(File.join(root, "*", "#{id}.jsonl")).find { |p| File.file?(p) }
  end

  # Sum usage across assistant lines → [totals, latest_model]. Returns
  # [nil, nil] if the file can't be read; zeroed totals if it has no usage yet.
  def self.sum_usage(path)
    totals = Hash.new(0)
    model = nil
    File.foreach(path) do |line|
      obj = begin
        JSON.parse(line)
      rescue StandardError
        next
      end
      next unless obj.is_a?(Hash)
      next unless obj["type"] == "assistant"

      message = obj["message"] || {}
      usage = message["usage"] || next
      model = message["model"] if message["model"]
      totals["input"]          += usage["input_tokens"].to_i
      totals["output"]         += usage["output_tokens"].to_i
      totals["cache_creation"] += usage["cache_creation_input_tokens"].to_i
      totals["cache_read"]     += usage["cache_read_input_tokens"].to_i
    end
    [BUCKETS.to_h { |b| [b, totals[b]] }, normalize_model(model)]
  rescue SystemCallError
    [nil, nil]
  end

  # Per-bucket (now - baseline), floored at 0 (a rotated/truncated transcript
  # can leave the baseline higher than the current totals).
  def self.bucket_delta(totals, baseline)
    BUCKETS.to_h { |b| [b, [totals[b].to_i - baseline[b].to_i, 0].max] }
  end

  # Dollar cost of a usage bucket hash for a model, or nil if buckets/model are
  # missing or the model isn't priced.
  def self.price(buckets, model)
    return nil if buckets.nil?

    rates = PRICING[normalize_model(model)]
    return nil unless rates

    per_mtok =
      buckets["input"].to_i          * rates[:input] +
      buckets["output"].to_i         * rates[:output] +
      buckets["cache_creation"].to_i * rates[:input] * CACHE_WRITE_MULTIPLIER +
      buckets["cache_read"].to_i     * rates[:input] * CACHE_READ_MULTIPLIER
    (per_mtok / 1_000_000.0).round(4)
  end

  # Drop a trailing tier suffix like "[1m]" so "claude-opus-4-8[1m]" prices.
  def self.normalize_model(model)
    model && model.to_s.sub(/\[[^\]]*\]\z/, "")
  end
end
