# frozen_string_literal: true

require "json"

# Reads a Claude Code or Codex session transcript and turns it into per-transition usage
# for the task-board event trail — so `bin/task move` can auto-stamp the model,
# token delta, and cost the agent burned, with the agent passing no flags.
#
# Claude transcripts live at ~/.claude/projects/<project-dir>/<session-id>.jsonl
# and carry per-assistant-message usage blocks. Codex transcripts live at
# ~/.codex/sessions/YYYY/MM/DD/*<thread-id>.jsonl and carry cumulative
# total_token_usage in event messages. Both paths normalize into the same bucket
# hash; the delta between two moves is the work done in the stage being left.
#
# Plain Ruby (no Rails) so bin/task can require it directly. Best-effort by
# design: a missing/unreadable transcript yields nil, and the caller falls back
# to recording only the deterministic spine.
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
    "claude-fable-5"    => { input: 10.0, output: 50.0 },
    "gpt-5.5"           => { input: 5.0,  output: 30.0, cache_read: 0.5 }
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
  def self.capture(session_id:, provider: "claude", baseline: nil, transcript_root: nil)
    provider = normalize_provider(provider)
    transcript_root ||= default_root(provider)
    path = transcript_for(session_id, transcript_root, provider: provider)
    return nil unless path

    totals, model = sum_usage(path, provider: provider)
    return nil if totals.nil?

    Result.new(model: model, totals: totals, delta: baseline && bucket_delta(totals, baseline))
  end

  def self.default_root(provider = "claude")
    case normalize_provider(provider)
    when "codex"
      File.join(Dir.home, ".codex", "sessions")
    else
      File.join(Dir.home, ".claude", "projects")
    end
  end

  # Glob the transcript by session id across project dirs (the dir is the launch
  # cwd, which differs in a worktree, so we don't reconstruct it — the id is
  # unique). Returns the path or nil.
  def self.transcript_for(session_id, root, provider: "claude")
    id = session_id.to_s.strip
    return nil if id.empty?

    pattern =
      if normalize_provider(provider) == "codex"
        File.join(root, "**", "*#{id}.jsonl")
      else
        File.join(root, "*", "#{id}.jsonl")
      end
    Dir.glob(pattern).find { |p| File.file?(p) }
  end

  # Sum usage across assistant lines → [totals, latest_model]. Returns
  # [nil, nil] if the file can't be read; zeroed totals if it has no usage yet.
  def self.sum_usage(path, provider: "claude")
    return sum_codex_usage(path) if normalize_provider(provider) == "codex"

    sum_claude_usage(path)
  end

  def self.sum_claude_usage(path)
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

  # Codex writes cumulative totals on each token_count event, so take the latest
  # total instead of summing events. cached_input_tokens is a subset of
  # input_tokens; storing it as cache_read preserves total input display while
  # letting pricing apply the cached-input discount.
  def self.sum_codex_usage(path)
    totals = Hash.new(0)
    model = nil
    File.foreach(path) do |line|
      obj = begin
        JSON.parse(line)
      rescue StandardError
        next
      end
      next unless obj.is_a?(Hash)

      payload = obj["payload"].is_a?(Hash) ? obj["payload"] : {}
      model = payload["model"] if payload["model"]
      model ||= payload.dig("collaboration_mode", "settings", "model")

      usage = payload.dig("info", "total_token_usage")
      next unless obj["type"] == "event_msg" && usage.is_a?(Hash)

      input = usage["input_tokens"].to_i
      cached = usage["cached_input_tokens"].to_i
      totals["input"] = [input - cached, 0].max
      totals["output"] = usage["output_tokens"].to_i
      totals["cache_creation"] = 0
      totals["cache_read"] = cached
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

    cache_creation_rate = rates.fetch(:cache_creation, rates[:input] * CACHE_WRITE_MULTIPLIER)
    cache_read_rate = rates.fetch(:cache_read, rates[:input] * CACHE_READ_MULTIPLIER)

    per_mtok =
      buckets["input"].to_i          * rates[:input] +
      buckets["output"].to_i         * rates[:output] +
      buckets["cache_creation"].to_i * cache_creation_rate +
      buckets["cache_read"].to_i     * cache_read_rate
    (per_mtok / 1_000_000.0).round(4)
  end

  def self.normalize_provider(provider)
    provider.to_s == "codex" ? "codex" : "claude"
  end

  # Drop a trailing tier suffix like "[1m]" so "claude-opus-4-8[1m]" prices.
  def self.normalize_model(model)
    model && model.to_s.sub(/\[[^\]]*\]\z/, "")
  end
end
