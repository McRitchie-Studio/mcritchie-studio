require "test_helper"

# [integration] THE RUN HAS TO REMEMBER WHAT IT DID.
#
# The namesake guard's floor is a REFUSAL: when it cannot tell two same-named
# humans apart it declines to write one, on purpose, because guessing at human
# identity is the defect it was built to stop. That floor is only correct if the
# refusal is READ — and it was not. The importer incremented a counter and moved
# on; `run.update!` persisted rows_seen and rows_changed and dropped the rest;
# the one line naming the human went through `vputs`, which is verbose-gated, so
# it never printed. A guard that quietly declines to write a person, leaving no
# trace, is indistinguishable from an importer that silently lost one.
#
# EVERY ASSERTION HERE READS THE ROW, not the in-memory Result. The in-memory
# half already worked and is not the gap (seed_players_collision_test covers
# it); a regression that reads `result[:namesake_collisions_skipped]` would stay
# green through the exact defect this file exists for.
class Nflverse::SeedPlayersRunRecordTest < ActiveSupport::TestCase
  SOURCE = "nflverse_players".freeze

  HEADER = "gsis_id,espn_id,pff_id,otc_id,pfr_id,first_name,common_first_name,last_name," \
           "position,latest_team,status,last_season,height,weight,headshot".freeze

  def csv(*rows) = ([HEADER] + rows).join("\n")

  def jefferson(gsis:, espn:, position:, team:)
    "#{gsis},#{espn},,,,Justin,Justin,Jefferson,#{position},#{team},ACT,2026,72,195,"
  end

  # The CSV that makes the guard refuse, reused from the collision suite: an
  # identified Jefferson, then a second Jefferson carrying NO identity key at
  # all, so no stable slug suffix can be derived for him.
  def refusing_csv
    csv(jefferson(gsis: "00-0036322", espn: "4262921", position: "WR", team: "MIN"),
        jefferson(gsis: "", espn: "", position: "LB", team: "CLE"))
  end

  def clean_csv
    csv(jefferson(gsis: "00-0036322", espn: "4262921", position: "WR", team: "MIN"))
  end

  def import(body)
    Nflverse::SeedPlayers.new(csv_body: body, upload_headshots: false, status_filter: "ACT").call
  end

  def last_run = ImportRun.for_source(SOURCE).order(:started_at).last

  setup do
    Athlete.delete_all
    Person.where(last_name: "Jefferson").delete_all
    ImportRun.delete_all
    ErrorLog.delete_all
  end

  test "the refused namesake is counted ON THE ROW, not only in memory" do
    result = import(refusing_csv)

    # Asserted only so a failure says WHICH half broke. This half already worked.
    assert_equal 1, result[:namesake_collisions_skipped],
                 "precondition: this CSV must actually make the guard refuse"

    run = ImportRun.last_success_for(SOURCE)
    assert run, "the import must have recorded a successful run"
    assert_equal 1, run.stats["namesake_collisions_skipped"],
                 "the refusal has to outlive the process that observed it"
  end

  test "the row names WHICH human was refused, not just how many" do
    import(refusing_csv)

    refusals = ImportRun.last_success_for(SOURCE).stats["namesake_refusals"]
    assert_equal 1, refusals.size, "one refusal, one record"

    refusal = refusals.first
    assert_equal "Justin Jefferson", refusal["name"]
    assert_equal "justin-jefferson", refusal["person_slug"]
    assert_equal "00-0036322", refusal["ours"], "the identifier the incumbent already holds"
    assert_nil refusal["theirs"], "this incoming row carried no identifier at all"
    assert refusal["reason"].present?, "a refusal an operator cannot explain is not actionable"
  end

  # The counter and the payload must describe the SAME event. Two tallies that
  # can disagree are worse than one, because the disagreement is silent.
  test "the counter and the named refusals agree" do
    import(refusing_csv)
    stats = ImportRun.last_success_for(SOURCE).stats

    assert_equal stats["namesake_collisions_skipped"], stats["namesake_refusals"].size
  end

  # NOT VERBOSE-GATED, and on stderr — the two properties that decide whether a
  # human ever meets this. Every caller that runs the importer non-interactively
  # discards its stdout, so `puts` here would be unconditional in the source and
  # invisible in the run that matters.
  test "a refusal is announced on stderr without asking for verbose" do
    _out, err = capture_io { import(refusing_csv) }

    assert_includes err, "REFUSED", "the refusal has to announce itself"
    assert_includes err, "Justin Jefferson", "naming the human is the only actionable part"
  end

  test "a clean import records no refusals and says nothing" do
    _out, err = capture_io { import(clean_csv) }

    assert_equal 0, ImportRun.last_success_for(SOURCE).stats.fetch("namesake_collisions_skipped", 0)
    assert_nil ImportRun.last_success_for(SOURCE).stats["namesake_refusals"]
    assert_not_includes err, "REFUSED", "silence has to mean something"
  end

  # The outage path stamps its own tally, because `track` marks the run failed
  # and the block never reaches its own update!. Without it, the row a rebuild
  # lane now reads would carry an empty hash on an outage — indistinguishable
  # from a run that reached the feed and found nothing.
  test "a feed outage persists its tally on the failed run" do
    importer = Nflverse::SeedPlayers.new(upload_headshots: false)
    importer.define_singleton_method(:open_source) { |_url| raise SocketError, "getaddrinfo" }
    capture_io { importer.call }

    run = last_run
    assert_equal "failed", run.status
    assert_equal 1, run.stats["feed_unavailable"],
                 "an outage has to be legible on the row, not only in a log line"
    assert_not ImportRun.fresh_success?(SOURCE),
               "an outage must not leave a fresh success behind"
  end

  test "an import that reads the feed leaves a fresh success behind" do
    import(clean_csv)

    assert ImportRun.fresh_success?(SOURCE)
  end
end
