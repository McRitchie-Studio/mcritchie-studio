# frozen_string_literal: true

require_relative "agent_session_usage"
require "json"
require "fileutils"

# Per-(session, task-slug) baseline of cumulative token usage — the state behind
# best-effort per-transition usage capture for the task-board timeline.
#
# A Claude session transcript is CUMULATIVE across the whole session (every task
# it touches), so to isolate the work done for ONE task's ONE stage we diff the
# session's current cumulative totals against a baseline snapshot taken when that
# session first TOUCHED the task. Three touch points seed the baseline:
#
#   * task CREATE             — `bin/task create` (so the DESIGN phase is measured)
#   * the build CLAIM         — `bin/task move <slug> building`
#   * a review/deploy INTENT  — `bin/task intent <slug> --to <stage>` and
#                               `bin/reviewer-select` (the review intent)
#
# so the first real WORK transition (designed→building, building→submitted,
# submitted→reviewed, reviewed→assembled, assembled→shipped) computes a true
# non-zero delta instead of the zeroed first-move baseline that made the
# `Designed→Building` and `Submitted→Reviewed` chips show a model name with zero
# tokens/cost.
#
# Plain Ruby (no Rails) so the standalone CLIs (bin/task, bin/release,
# bin/reviewer-select) can require it directly. Best-effort by design: every
# operation swallows IO/parse errors and degrades to nil/false so a usage hiccup
# can never abort a move, an intent, or a release step.
class TaskUsageBaseline
  # +session+ is the agent session id; +dir+ is where the per-session baseline
  # JSON lives (callers resolve it — defaults under <projects>/.agents/task-usage;
  # tests point it at a tmp path). +transcript_root+ defaults to the Claude
  # projects dir AgentSessionUsage reads.
  def initialize(session:, dir:, transcript_root: AgentSessionUsage.default_root)
    @session = session.to_s.strip
    @dir = dir.to_s
    @transcript_root = transcript_root
  end

  # The state file for THIS session: a JSON object keyed by task slug, each value
  # the session's cumulative bucket totals snapshot. Same path shape bin/task has
  # always written, so the CLAIM (bin/task) and a later review move share state.
  def state_path
    File.join(@dir, "#{@session.gsub(/[^A-Za-z0-9._-]/, '')}.json")
  end

  # The stored baseline bucket-hash for +slug+, or nil when none/unreadable.
  def read(slug)
    return nil if blank?

    path = state_path
    return nil unless File.exist?(path)

    (JSON.parse(File.read(path)) || {})[slug.to_s]
  rescue StandardError
    nil
  end

  # Persist +totals+ as the baseline for +slug+, merging into any existing state.
  def write(slug, totals)
    return if blank?

    path = state_path
    FileUtils.mkdir_p(File.dirname(path))
    data = File.exist?(path) ? (JSON.parse(File.read(path)) rescue {}) : {}
    data[slug.to_s] = totals
    File.write(path, "#{JSON.generate(data)}\n")
  rescue StandardError
    nil
  end

  # Seed the baseline for +slug+ from the session's CURRENT cumulative totals
  # IFF none exists yet (idempotent — never resets an in-progress baseline).
  # Returns true when it wrote a fresh baseline, false otherwise. This is what
  # the CLAIM and the review/deploy INTENT call so the first real work transition
  # has a true baseline to diff against.
  def seed(slug)
    return false if blank?
    return false unless read(slug).nil?

    result = AgentSessionUsage.capture(session_id: @session, transcript_root: @transcript_root)
    return false unless result

    write(slug, result.totals)
    true
  rescue StandardError
    false
  end

  # Capture the per-transition usage for +slug+: diff the session's current
  # cumulative totals against the stored baseline, then ADVANCE the baseline to
  # the current totals so the next move measures from here. Returns the
  # AgentSessionUsage::Result (model + delta), or nil when there's no transcript.
  # Mirrors bin/task's autofill so every move path computes deltas identically.
  def capture_delta(slug)
    return nil if blank?

    result = AgentSessionUsage.capture(
      session_id: @session,
      baseline: read(slug),
      transcript_root: @transcript_root
    )
    return nil unless result

    write(slug, result.totals)
    result
  rescue StandardError
    nil
  end

  private

  def blank?
    @session.empty? || @dir.empty?
  end
end
