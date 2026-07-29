# frozen_string_literal: true

require "json"
require "time"
require_relative "agent_session_usage"
require_relative "usage_pricing"

# Reads a fan-out session's CHILD subagent transcripts and attributes their token
# spend back to the AgentActivity rows that AUTHORED it — the fix for "token
# attribution stops after fan-out".
#
# WHY. An activity's usage is normally a transcript-delta measured against the
# PARENT ~/.claude/projects/*/<sid>.jsonl only (AgentSessionUsage). After the
# supervisor delegates, the parent transcript goes QUIET and all real spend moves
# into CHILD transcripts at ~/.claude/projects/<proj>/<sid>/subagents/agent-<id>.jsonl
# (each with a sibling .meta.json naming its agentType/soul + spawn tree). Nothing
# read those, so every post-delegation activity measured a ZERO parent delta and
# rendered "—" on the feed. This reads them.
#
# MODEL — per-AUTHOR partition. Each activity is measured against the transcript of
# the agent that AUTHORED it: the parent for the root session's own turns, each
# subagent's child transcript for the activities it narrated (a reviewer's own
# review; the supervisor's nil-lane orchestration). Every DISTINCT assistant turn
# (deduped by message.id — one API turn is serialized once per content block, all
# copies carrying the SAME usage, so a naive sum multiplies it) is assigned to
# EXACTLY ONE activity: the one open in the turn's LANE at the turn's timestamp.
# Summing per activity therefore PARTITIONS the session's whole spend (parent +
# every child) across the rows — no double-count, and the rows reconcile to the
# real total across the WHOLE trajectory instead of just the pre-fan-out part.
#
# LANE resolution. A subagent narrates its activities with `--agent <soul>`, so its
# child transcript's agentType maps to those soul-lane activities. A SUPERVISOR
# subagent (e.g. the orchestrating session of a review wave) narrates the orchestration on the NIL lane, so
# its agentType has no matching soul-lane activity → it falls back to the nil lane,
# alongside the true parent. That is deliberate: the nil-lane activities during the
# supervisor's window carry the supervisor's real spend, and the pre/post-delegation
# nil-lane activities carry the parent's — split cleanly by timestamp.
#
# GUARD. With no child transcripts the session isn't a fan-out; reconcile returns
# NO patches so a plain session's live close-diff measurements are left untouched.
#
# Plain Ruby (no Rails), best-effort: any parse/IO hiccup degrades to fewer patches
# (or none), never an exception — telemetry must never break the work it observes.
class AgentFanoutUsage
  # One distinct assistant turn from a transcript. `id` is message.id (the dedupe
  # key); `ts` the wall-clock the turn landed; the four buckets its usage.
  Turn = Struct.new(:id, :ts, :model, :input, :output, :cache_creation, :cache_read,
                    keyword_init: true)

  # One transcript that authored activities: `soul` is the acting agent (nil for the
  # parent/root session), `turns` its deduped assistant turns.
  Author = Struct.new(:soul, :turns, keyword_init: true)

  # Compute the per-activity usage patches for a fan-out session, or [] when the
  # session has no child transcripts (not a fan-out — leave live values alone).
  #
  # `activities` is the session's activity windows as the board knows them — an
  # array of hashes carrying (id, agent, opened_at, closed_at); string OR symbol
  # keys accepted, opened_at/closed_at as Time or ISO8601 string. Returns an array
  # of patch hashes (string keys) ready to POST, one per activity that received any
  # spend:
  #   { "activity_id", "model", "tokens_in", "tokens_out", "cache_creation_tokens",
  #     "cache_read_tokens", "cost" }
  # cache_creation_tokens is what lets the SERVER re-derive cost at an overridden rate;
  # "cost" is the LIST-price fallback for a model with no known rate.
  def self.reconcile(session_id:, activities:, transcript_root: nil, provider: "claude")
    new(session_id: session_id, transcript_root: transcript_root, provider: provider)
      .reconcile(activities)
  rescue StandardError
    []
  end

  def initialize(session_id:, transcript_root: nil, provider: "claude")
    @session_id = session_id.to_s
    @provider = AgentSessionUsage.normalize_provider(provider)
    @root = transcript_root || AgentSessionUsage.default_root(@provider)
  end

  # The subagent child transcripts under this session's subagents/ dir, as Authors
  # (one per child, soul = its meta agentType). [] when the dir is absent/empty.
  def children
    Dir.glob(File.join(@root, "*", @session_id, "subagents", "agent-*.jsonl")).filter_map do |path|
      soul = child_soul(path)
      turns = parse_turns(path)
      next nil if turns.empty?

      Author.new(soul: soul, turns: turns)
    end
  end

  # The root/parent transcript as an Author (soul nil), or nil when unreadable.
  def parent_author
    path = AgentSessionUsage.transcript_for(@session_id, @root, provider: @provider)
    return nil unless path

    turns = parse_turns(path)
    turns.empty? ? nil : Author.new(soul: nil, turns: turns)
  end

  def reconcile(activities)
    kids = children
    return [] if kids.empty? # not a fan-out session — don't disturb live measurements

    acts = normalize_activities(activities)
    return [] if acts.empty?

    authors = ([parent_author] + kids).compact
    sums = Hash.new { |h, k| h[k] = { input: 0, output: 0, cache_creation: 0, cache_read: 0, models: Hash.new(0) } }

    authors.each do |author|
      lane_acts = lane_activities(acts, author.soul)
      next if lane_acts.empty?

      author.turns.each do |turn|
        act = assign_activity(turn.ts, lane_acts)
        next unless act

        agg = sums[act[:id]]
        agg[:input]          += turn.input
        agg[:output]         += turn.output
        agg[:cache_creation] += turn.cache_creation
        agg[:cache_read]     += turn.cache_read
        agg[:models][turn.model] += turn.output if turn.model # weight the model by output
      end
    end

    sums.map { |activity_id, agg| patch_for(activity_id, agg) }
  end

  # ── Attribution ────────────────────────────────────────────────────────────

  # The lane an author's turns belong to: its soul when that soul has activities of
  # its own (a reviewer narrating `--agent carl`), else the NIL lane (the parent, or
  # a supervisor subagent that narrated the orchestration un-agented).
  def lane_activities(acts, soul)
    lane = soul if soul && acts.any? { |a| a[:agent] == soul }
    acts.select { |a| a[:agent] == lane }.sort_by { |a| a[:opened_at] }
  end

  # The activity open in a lane at time `ts`: the last one opened at/before ts,
  # bounded above by the NEXT activity's open (an intermediate gap belongs to the
  # preceding activity), or — for the final activity — by its own close (a turn
  # after the last activity closed is an unnarrated orphan → nil, dropped). A turn
  # just before the lane's first open (a pre-open sibling of the same turn) is graced
  # onto the first activity so it is still counted.
  def assign_activity(ts, lane_acts)
    return nil if lane_acts.empty?
    return lane_acts.first if ts < lane_acts.first[:opened_at]

    idx = lane_acts.rindex { |a| a[:opened_at] <= ts }
    act = lane_acts[idx]
    upper = lane_acts[idx + 1] ? lane_acts[idx + 1][:opened_at] : act[:closed_at]
    return nil if upper && ts >= upper

    act
  end

  # Turn the summed buckets into a POST-ready patch. tokens_in folds cache_creation
  # into the fresh count (matching AgentSessionUsage.Result#tokens_in); cache_read is
  # priced but never counted. Cost is the shared UsagePricing SoT for the dominant
  # model. Zero-spend aggregates never reach here (only activities that got turns).
  #
  # cache_creation_tokens rides along UN-FOLDED so the SERVER can split tokens_in back
  # out and re-derive this cost at an operator's overridden rate (UsagePricing
  # .cost_from_capture). Without it the server correctly REFUSES to derive — it cannot
  # tell input from cache-write, and pricing the folded count as pure input would bill
  # cache writes at 1x instead of 2x — so every reconciled fan-out activity would stay
  # pinned to LIST price forever. Fan-out is first-class here, so that is a large share
  # of all activities.
  def patch_for(activity_id, agg)
    model = agg[:models].max_by { |_m, weight| weight }&.first
    buckets = {
      "input" => agg[:input], "output" => agg[:output],
      "cache_creation" => agg[:cache_creation], "cache_read" => agg[:cache_read]
    }
    {
      "activity_id"           => activity_id,
      "model"                 => model,
      "tokens_in"             => agg[:input] + agg[:cache_creation],
      "tokens_out"            => agg[:output],
      "cache_creation_tokens" => agg[:cache_creation],
      "cache_read_tokens"     => agg[:cache_read],
      "cost"                  => AgentSessionUsage.price(buckets, model)
    }
  end

  # ── Transcript + meta parsing ────────────────────────────────────────────────

  # A child transcript's soul from its sibling .meta.json `agentType` (down-cased),
  # or nil. The meta rides beside the .jsonl as agent-<id>.meta.json.
  def child_soul(jsonl_path)
    meta_path = jsonl_path.sub(/\.jsonl\z/, ".meta.json")
    return nil unless File.file?(meta_path)

    meta = JSON.parse(File.read(meta_path))
    slug = meta["agentType"].to_s.strip.downcase
    slug.empty? ? nil : slug
  rescue StandardError
    nil
  end

  # Parse a Claude transcript into DISTINCT assistant turns, deduped by message.id
  # (one API turn is serialized once per content block — same message.id, same
  # usage — so a naive per-line sum multiplies it; we keep the first sighting of each
  # id). Skips non-assistant / usage-less / malformed lines. Best-effort → [].
  def parse_turns(path)
    return [] unless path && File.file?(path)

    seen = {}
    turns = []
    File.foreach(path) do |line|
      obj = safe_parse(line)
      next unless obj.is_a?(Hash) && obj["type"] == "assistant"

      message = obj["message"]
      next unless message.is_a?(Hash)

      usage = message["usage"]
      next unless usage.is_a?(Hash)

      id = message["id"].to_s
      key = id.empty? ? obj["uuid"].to_s : id
      next if key.empty? || seen[key]

      seen[key] = true
      turns << Turn.new(
        id: key,
        ts: parse_time(obj["timestamp"]),
        model: AgentSessionUsage.normalize_model(message["model"]),
        input: usage["input_tokens"].to_i,
        output: usage["output_tokens"].to_i,
        cache_creation: usage["cache_creation_input_tokens"].to_i,
        cache_read: usage["cache_read_input_tokens"].to_i
      )
    end
    turns.reject { |t| t.ts.nil? }
  rescue SystemCallError
    []
  end

  # ── Input normalization + tiny helpers ───────────────────────────────────────

  # Coerce the board's activity rows into { id, agent(nil|soul), opened_at:Time,
  # closed_at:Time|nil }, dropping any without a usable id/opened_at. Accepts string
  # or symbol keys and Time or ISO8601 string timestamps.
  def normalize_activities(activities)
    Array(activities).filter_map do |a|
      id = fetch(a, :id)
      opened = parse_time(fetch(a, :opened_at))
      next nil if id.nil? || opened.nil?

      agent = fetch(a, :agent).to_s.strip
      { id: id, agent: agent.empty? ? nil : agent, opened_at: opened, closed_at: parse_time(fetch(a, :closed_at)) }
    end
  end

  def fetch(hash, key)
    return nil unless hash.respond_to?(:[])

    hash[key] || hash[key.to_s] || hash[key.to_sym]
  end

  def parse_time(value)
    return value if value.is_a?(Time)
    return nil if value.nil? || value.to_s.strip.empty?

    Time.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def safe_parse(line)
    JSON.parse(line)
  rescue StandardError
    nil
  end
end
