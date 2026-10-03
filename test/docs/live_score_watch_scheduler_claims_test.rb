# frozen_string_literal: true

require "test_helper"

# WHAT docs/agents/agents/turf_monster/sops/live-score-watch.md IS ALLOWED TO SAY
# ABOUT WHO ELSE POLLS.
#
# turf-monster PR #835 (2026-09-30) put the NFL poller on a clock: config/schedule.yml
# gained `nfl_live_poll` (*/5 * * * *) and `nfl_silent_gap_check` (37 */6 * * *), and
# Nfl::LivePollJob became a second non-test caller of Nfl::LiveScores::PollCycle. The
# SOP went on saying the opposite for a day:
#
#   "There is no scheduled job behind it — `bin/nfl-live-poll` is the only non-test
#    caller of `Nfl::LiveScores::PollCycle`, and `config/schedule.yml` has no NFL
#    entry — so an agent running this SOP is the sole path by which production
#    contests re-score."
#
# All three clauses were false, and the sentence is the one that justifies running
# the act at all. THAT IS WHY THIS GUARD IS NOT DOC HYGIENE. An agent reading "sole
# path" believes a week cannot be polled unless they poll it — the mirror of the
# belief that let regular-season week 2 silently vanish with 7 paying entries on it.
# Prose that asserts what the code does not do reads exactly like freshly verified
# prose, and nothing re-reads it.
#
# THE SOP MUST NOT SWING THE OTHER WAY EITHER. `live-score-watch` is still the right
# tool for a contest an operator is actively watching; the cron is a FLOOR on latency
# (five minutes), not a replacement, and the builder of #835 said so in the job. So
# lane 2 pins the correction's own survival as hard as lane 1 pins the retired claim:
# a later editor who deletes the "not a replacement" half turns this red too.
#
# ── THREE LANES, and only one of them can run on CI ─────────────────────────────
#
#   1. ABSENCE CLAIMS (everywhere). The prose may not assert that nothing polls on a
#      schedule. Five patterns, each proven to bite by a control below.
#   2. THE HANDLES (everywhere). The prose must name the scheduled entries, their job
#      class, the file that declares them, and the settled-contest verdicts — so a
#      rewrite cannot quietly drop the correction and leave a vague paragraph that
#      passes lane 1 by saying nothing at all.
#   3. THE SOURCE (only where turf-monster is checked out). Reads that repo's
#      config/schedule.yml and poll_cycle.rb and asserts the SOP AGREES with them:
#      every scheduled NFL entry is named with its cron expression, and the anomaly
#      table lists exactly the anomaly kinds the cycle can raise — neither short nor
#      invented. THIS IS THE LANE WITH A FEEDBACK LOOP, and it adds nothing on a CI
#      runner that has no sibling checkout, which is why it is never this file's only
#      assertion. Same shape as the sibling lane in
#      test/docs/fast_lane_hub_path_docs_test.rb ("no satellite checkout carries a
#      fast lane script").
#
# WHY LANE 3 CANNOT BE THE WHOLE GUARD, stated so nobody "fixes" it by deleting the
# other two: this is the hub, the schedule lives one repo over, and the hub's CI
# checks out no sibling. A guard that only reads the sibling is green-by-absence in
# the one place that runs on every PR.
#
# AND LANE 3 READS A WORKING TREE, not a ref. Whatever branch ../turf-monster happens
# to be sitting on is what it measures, so a desk parked on a pre-#835 branch can red
# it for a reason that is not this repo's. That is the correct failure to have — it
# says "these two files disagree", which is true of that checkout — but confirm the
# branch before editing the prose:
#   git -C ../turf-monster rev-parse --abbrev-ref HEAD
#
# WHY LANE 1 IS A PATTERN SCAN AND NOT A GREP FOR THE DELETED SENTENCE. A test that
# pins the exact retired string passes the moment somebody re-words the same false
# claim, which is the likeliest way one comes back. These assert the RULE. The limit,
# stated rather than hidden: a sufficiently novel phrasing of "nothing else polls"
# can evade all five patterns. Lane 2 is what makes that evasion loud, because the
# evading sentence has to coexist with the handles that contradict it.
#
# NO `/x` ON ANY PATTERN HERE, deliberately. Free-spacing mode DELETES literal
# whitespace, and a sibling guard in this repo carried `needs? Mr\. McRitchie` under
# /xi for its whole life, compiling to something that cannot match English — four of
# its five alternations never fired. Every space below is a real `\s+`.
class LiveScoreWatchSchedulerClaimsTest < ActiveSupport::TestCase
  SOP = "docs/agents/agents/turf_monster/sops/live-score-watch.md"

  # The sibling repo that owns every fact this SOP describes.
  SATELLITE = "turf-monster"
  SCHEDULE = "config/schedule.yml"
  POLL_CYCLE = "app/services/nfl/live_scores/poll_cycle.rb"

  # The NFL entries PR #835 added. Named here so lane 2 holds on CI; lane 3 re-derives
  # the real set from the file and would red if this list went stale in either
  # direction.
  NFL_CRON_ENTRIES = %w[nfl_live_poll nfl_silent_gap_check].freeze

  # ── LANE 1 ───────────────────────────────────────────────────────────────────
  #
  # Each key is a way of asserting "nothing polls but you". The value is what a
  # reader is routed into by believing it, which is what the failure message says —
  # a guard that only prints a regex teaches nobody why the sentence was wrong.
  ABSENCE_CLAIMS = {
    /no\s+scheduled\s+job/i =>
      "there IS a scheduled job: nfl_live_poll runs Nfl::LivePollJob every five minutes",
    /\bsole\s+path\b/i =>
      "running this act is not the sole path by which production contests re-score",
    /\bno\s+NFL\s+entry\b/i =>
      "config/schedule.yml carries two NFL entries (#{NFL_CRON_ENTRIES.join(', ')})",
    /no\s+queue,?\s+no\s+scheduler/i =>
      "the agent's loop is not the scheduler, but a scheduler exists beside it",
    /\bnothing\s+(?:else\s+)?(?:polls|re-scores|reschedules)\b/i =>
      "something else does poll: the cron tick, unconditionally, all week",
  }.freeze

  # A NEGATED MENTION IS NOT A CLAIM, and this is the one pattern that needs the
  # distinction. The corrected SOP says `bin/nfl-live-poll` is "no longer the only
  # non-test caller", which must stay legal; a bare assertion that it IS the only one
  # must not. So the match is an offender only when nothing in the WINDOW before it
  # negates or dates it.
  ONLY_CALLER = /\bthe\s+only\s+non-test\s+caller\b/i
  NEGATED_BEFORE = /no\s+longer|used\s+to\s+be|until\s+\d|was\s+(?:the\s+)?$|claimed/i
  NEGATION_WINDOW = 60

  # ── LANE 2 ───────────────────────────────────────────────────────────────────
  #
  # Factual handles, not wording: each is a name a reader can grep for in the repo
  # that owns it. A paragraph that keeps all of these cannot also be vague about who
  # polls.
  REQUIRED_HANDLES = [
    "nfl_live_poll",
    "nfl_silent_gap_check",
    "Nfl::LivePollJob",
    SCHEDULE,
    "settled_contest",
    "settled_contest_coscored",
    "--allow-settled",
  ].freeze

  # THE ONE WORDING PIN, and it is deliberate. Lane 1 can only ever remove a false
  # claim; nothing in it stops a later editor from deleting the correction's second
  # half and leaving a reader to conclude the act was superseded. The act was NOT
  # superseded — five minutes is a latency floor for an UNWATCHED slate, and an
  # operator watching a live contest still wants the 30-second cadence. One of these
  # has to survive. Stated as an alternation so a rewrite has room to say it better.
  NOT_SUPERSEDED = [
    /floor\s+on\s+latency/i,
    /not\s+a\s+replacement\s+for\s+the\s+watch/i,
    /keeps\s+its\s+whole\s+purpose/i,
  ].freeze

  # Non-vacuity floors. A scan whose subject went missing must fail, not pass.
  MIN_SOP_LINES = 200
  MIN_TABLE_ROWS = 8

  # ── LANE 1 ───────────────────────────────────────────────────────────────────

  test "the SOP never claims that nothing polls on a schedule" do
    body = sop_body
    assert_operator body.lines.length, :>=, MIN_SOP_LINES,
                    "#{SOP} is #{body.lines.length} lines — the scan lost its subject"

    offenders = absence_offenders(body)
    assert_empty offenders, <<~MSG.strip
      #{SOP} asserts that nothing else polls. Each line below was true before
      turf-monster PR #835 and is false now:

      #{offenders.map { |o| "  :#{o[:line]}  #{o[:text]}\n            -> #{o[:why]}" }.join("\n")}

      Read #{SATELLITE}'s #{SCHEDULE} before re-wording this: nfl_live_poll and
      nfl_silent_gap_check are both registered with active_job: true.
    MSG
  end

  # ── LANE 2 ───────────────────────────────────────────────────────────────────

  test "the SOP names the schedule it now has to account for" do
    body = sop_body

    missing = REQUIRED_HANDLES.reject { |handle| body.include?(handle) }
    assert_empty missing, <<~MSG.strip
      #{SOP} no longer names #{missing.join(', ')}. Lane 1 can only delete a false
      claim; these are what keep the paragraph SPECIFIC, so a vague rewrite cannot
      pass by saying nothing at all. Every one of them is greppable in #{SATELLITE}.
    MSG
  end

  test "the SOP still says the cron did not supersede this act" do
    body = sop_body
    assert NOT_SUPERSEDED.any? { |pattern| pattern.match?(body) }, <<~MSG.strip
      #{SOP} no longer says the schedule is a LATENCY FLOOR rather than a
      replacement for the watch. The correction has two halves and this is the
      second one: a contest an operator is actively watching still wants the
      30-second cadence, the per-play readout and a human reading the anomalies.
      Nfl::LivePollJob says so in its own header. Say it in one of these forms, or
      add yours to NOT_SUPERSEDED here: #{NOT_SUPERSEDED.map(&:source).join(' | ')}
    MSG
  end

  # ── LANE 3 — rides along where the sibling checkout exists ───────────────────

  test "the SOP agrees with turf-monster's schedule file where it can be read" do
    schedule = satellite_file(SCHEDULE)
    skip_note = "no #{SATELLITE} checkout under #{projects_root} — lane 3 inspected nothing"
    return assert(true, skip_note) unless schedule

    body = sop_body
    present = NFL_CRON_ENTRIES.select { |entry| schedule.match?(/^#{Regexp.escape(entry)}:/) }

    # THE IMPLICATION, in the direction the task asked for: entries present => the
    # SOP may not claim there is no scheduler, and must name each one WITH its cron
    # expression. A cron expression is the fact an agent acts on (how stale the board
    # can be), and it is the half most likely to drift silently.
    present.each do |entry|
      assert body.include?(entry),
             "#{SCHEDULE} registers #{entry} and #{SOP} never names it"

      cron = schedule[/^#{Regexp.escape(entry)}:\s*\n\s*cron:\s*"([^"]+)"/, 1]
      next unless cron

      assert body.include?(cron),
             "#{SCHEDULE} runs #{entry} on #{cron.inspect} and #{SOP} does not quote that cadence"
    end

    assert_empty absence_offenders(body),
                 "#{SCHEDULE} registers #{present.join(', ')} while #{SOP} still claims nothing polls"

    # Says what this run actually inspected, so a green is never mistaken for proof
    # on a machine that had nothing to read.
    assert_equal NFL_CRON_ENTRIES.sort, present.sort,
                 "#{SCHEDULE} no longer registers all of #{NFL_CRON_ENTRIES.join(', ')} — " \
                 "it has #{present.join(', ').inspect}. If the cron was deliberately removed, " \
                 "this guard's premise changed and the SOP has to be re-read, not re-pinned."
  end

  test "the anomaly table lists exactly the kinds the cycle can raise" do
    source = satellite_file(POLL_CYCLE)
    return assert(true, "no #{SATELLITE} checkout under #{projects_root} — lane 3 inspected nothing") unless source

    verdict = completeness_verdict(source, sop_body)

    assert_operator verdict[:raised].length, :>=, MIN_TABLE_ROWS,
                    "#{POLL_CYCLE} yielded #{verdict[:raised].length} anomaly kinds — the scrape stopped working"
    assert_operator verdict[:documented].length, :>=, MIN_TABLE_ROWS,
                    "the anomaly table in #{SOP} yielded #{verdict[:documented].length} rows — the parse broke"

    assert_empty verdict[:undocumented], <<~MSG.strip
      #{POLL_CYCLE} raises #{verdict[:undocumented].join(', ')} and the anomaly table in
      #{SOP} has no row for it. The table is the set an agent triages from, so a kind
      missing from it is a kind nobody knows what to do with. This is how "seven
      kinds" went three short.
    MSG

    assert_empty verdict[:invented], <<~MSG.strip
      the anomaly table in #{SOP} documents #{verdict[:invented].join(', ')}, which
      #{POLL_CYCLE} never raises. Prose asserting what the code does not do is the
      exact defect this guard was filed for — in the opposite direction.
    MSG
  end

  # ── CONTROLS — every lane above, proven to bite ──────────────────────────────
  #
  # A docs guard with no control is a guard nobody has seen fail. These replay the
  # retired sentence and a few of its likely re-wordings against the same predicates
  # the lanes use, so the mutation proof travels with the guard instead of living in
  # a PR comment.

  RETIRED_PARAGRAPH = <<~PROSE
    This act writes `Goal` rows, and those rows settle contests people paid to
    enter. There is no scheduled job behind it — `bin/nfl-live-poll` is the only
    non-test caller of `Nfl::LiveScores::PollCycle`, and `config/schedule.yml` has
    no NFL entry — so an agent running this SOP is the **sole path by which
    production contests re-score.**
  PROSE

  test "the absence lane reddens on the paragraph this task deleted" do
    fired = absence_offenders(RETIRED_PARAGRAPH).map { |o| o[:pattern] }

    assert_includes fired, /no\s+scheduled\s+job/i
    assert_includes fired, /\bsole\s+path\b/i
    assert_includes fired, /\bno\s+NFL\s+entry\b/i
    assert_includes fired, ONLY_CALLER
    assert_operator fired.length, :>=, 4, "only #{fired.length} pattern(s) fired on the retired paragraph"
  end

  test "each absence pattern fires on a sentence written for it" do
    {
      /no\s+scheduled\s+job/i => "There is no scheduled job behind it.",
      /\bsole\s+path\b/i => "You are the sole path by which contests re-score.",
      /\bno\s+NFL\s+entry\b/i => "`config/schedule.yml` has no NFL entry.",
      /no\s+queue,?\s+no\s+scheduler/i => "This is the agent's loop — no queue, no scheduler.",
      /\bnothing\s+(?:else\s+)?(?:polls|re-scores|reschedules)\b/i => "Nothing else polls ESPN.",
    }.each do |pattern, sentence|
      fired = absence_offenders(sentence).map { |o| o[:pattern] }
      assert_includes fired, pattern, "#{pattern.inspect} did not fire on #{sentence.inspect}"
    end
  end

  test "a negated mention of the only caller is legal and a bare one is not" do
    legal = "so `bin/nfl-live-poll` is no longer the only non-test caller of `PollCycle`."
    assert_empty absence_offenders(legal),
                 "the corrected wording must stay legal, or the fix cannot be written"

    bare = "`bin/nfl-live-poll` is the only non-test caller of `PollCycle`."
    assert_includes absence_offenders(bare).map { |o| o[:pattern] }, ONLY_CALLER
  end

  test "the handles lane reddens when the correction is rewritten away" do
    vague = "Something may also poll on a schedule; check before you start."
    missing = REQUIRED_HANDLES.reject { |handle| vague.include?(handle) }
    assert_equal REQUIRED_HANDLES.length, missing.length,
                 "a paragraph naming nothing must fail lane 2 on every handle"

    assert_empty absence_offenders(vague),
                 "and it passes lane 1 — which is the whole reason lane 2 exists"
  end

  test "the not-superseded lane reddens when the second half is deleted" do
    deprecating = "The cron replaced this act. Do not run it by hand any more."
    refute NOT_SUPERSEDED.any? { |pattern| pattern.match?(deprecating) },
           "a paragraph that deprecates the act must not satisfy the not-superseded lane"
  end

  test "the completeness lane reddens in both directions" do
    table = <<~TABLE
      | Kind | What it means | What to do |
      |---|---|---|
      | `fetch_failed` | x | y |
      | `settled_contest` | x | y |
    TABLE

    # A kind added to the cycle and not to the table.
    added = %(Anomaly.new(kind: "fetch_failed")\nAnomaly.new(kind: "settled_contest")\nAnomaly.new(kind: "brand_new_anomaly"))
    verdict = completeness_verdict(added, table)
    assert_equal ["brand_new_anomaly"], verdict[:undocumented]
    assert_empty verdict[:invented]

    # A row the cycle cannot raise — the same defect pointing the other way.
    retired = %(Anomaly.new(kind: "fetch_failed"))
    verdict = completeness_verdict(retired, table)
    assert_equal ["settled_contest"], verdict[:invented]
    assert_empty verdict[:undocumented]

    # And the real pair agrees, where it can be read.
    source = satellite_file(POLL_CYCLE)
    return assert(true, "no #{SATELLITE} checkout — real pair not compared") unless source

    real = completeness_verdict(source, sop_body)
    assert_empty real[:undocumented] + real[:invented]
  end

  test "the kind scrape reads real constants out of the cycle" do
    source = satellite_file(POLL_CYCLE)
    return assert(true, "no #{SATELLITE} checkout — nothing to scrape") unless source

    kinds = anomaly_kinds(source)
    assert_includes kinds, "settled_contest"
    assert_includes kinds, "settled_contest_coscored"
    assert_includes kinds, "unknown_team"

    fixture = %(@anomalies << Anomaly.new(kind: "made_up_kind", detail: "x"))
    assert_equal ["made_up_kind"], anomaly_kinds(fixture),
                 "the scrape must read the literal, not a hard-coded list"
  end

  private

  def sop_body
    @sop_body ||= Rails.root.join(SOP).read
  end

  # Returns one row per asserted absence: the pattern that fired, the line, the text,
  # and why believing it misroutes a reader.
  def absence_offenders(body)
    offenders = []

    ABSENCE_CLAIMS.each do |pattern, why|
      body.to_enum(:scan, pattern).each do
        match = Regexp.last_match
        offenders << row(body, match, pattern, why)
      end
    end

    body.to_enum(:scan, ONLY_CALLER).each do
      match = Regexp.last_match
      window = body[[match.begin(0) - NEGATION_WINDOW, 0].max...match.begin(0)].to_s
      next if NEGATED_BEFORE.match?(window)

      offenders << row(body, match, ONLY_CALLER,
                       "Nfl::LivePollJob is a second non-test caller of PollCycle")
    end

    offenders.sort_by { |o| o[:line] }
  end

  def row(body, match, pattern, why)
    line = body[0, match.begin(0)].count("\n") + 1
    { line: line, text: body.lines[line - 1].to_s.strip, pattern: pattern, why: why }
  end

  # Both directions of the table-vs-source comparison, in one place so the controls
  # drive the SAME arithmetic the lane does.
  def completeness_verdict(source, body)
    raised = anomaly_kinds(source)
    documented = table_kinds(body)
    { raised: raised, documented: documented,
      undocumented: raised - documented, invented: documented - raised }
  end

  # Every anomaly kind the cycle can report, read off the literals rather than a list
  # kept here by hand — a hand-kept list is the defect, one level up.
  def anomaly_kinds(source)
    source.scan(/kind:\s*"([a-z_]+)"/).flatten.uniq.sort
  end

  # The first cell of every row in the anomaly table: `| `kind` | ... |`.
  def table_kinds(body)
    body.lines.filter_map { |line| line[/\A\|\s*`([a-z_]+)`\s*\|/, 1] }.uniq.sort
  end

  # /Users/alex/projects — the parent of every checkout, from a primary OR a desk.
  def projects_root
    @projects_root ||= if Rails.root.to_s.include?("/.worktrees/")
                         Rails.root.join("../../..")
                       else
                         Rails.root.join("..")
                       end.cleanpath
  end

  def satellite_file(relative)
    path = projects_root.join(SATELLITE, relative)
    path.file? ? path.read : nil
  end
end
