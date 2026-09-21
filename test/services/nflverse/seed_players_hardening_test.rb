require "test_helper"

# [integration] The two hardening fixes from shannon's re-review of PR #1488.
#
# Both matter because this service runs as a POST-DEPLOY COMMAND inside
# `bin/release`: an uncaught raise there aborts the entire ship, and a wedged
# import means the data never refreshes again.
class Nflverse::SeedPlayersHardeningTest < ActiveSupport::TestCase
  HEADER = "gsis_id,espn_id,pff_id,otc_id,pfr_id,nfl_id,first_name,common_first_name," \
           "last_name,position,latest_team,status,last_season,height,weight".freeze

  def row(gsis:, nfl_id:, last: "Burrow")
    "#{gsis},4038941,,,,#{nfl_id},Joe,Joe,#{last},QB,CIN,ACT,2026,76,215"
  end

  def csv(*rows) = ([HEADER] + rows).join("\n")

  def import(body)
    Nflverse::SeedPlayers.new(csv_body: body, upload_headshots: false, status_filter: "ACT").call
  end

  setup do
    Athlete.delete_all
    Person.where(last_name: %w[Burrow Jefferson]).delete_all
    ImportRun.delete_all
  end

  # --- the wedge ----------------------------------------------------------
  #
  # nflverse_id is written by build_attrs and UNIQUELY INDEXED, but was not
  # probed. A row whose nflverse_id already belonged to another athlete fell
  # through to the name path; update! then raised into the caller's rescue,
  # committing a namesake pair with no league IDs — and the next run died on
  # index_people_on_slug with an uncaught RecordNotUnique.

  test "an athlete is found by nflverse_id when no other identifier matches" do
    import(csv(row(gsis: "00-0036442", nfl_id: "NFL-123")))
    athlete = Athlete.find_by(nflverse_id: "NFL-123")
    assert athlete, "precondition: the first import should have stored nflverse_id"

    # Same person, arriving with NO gsis/espn/pff/otc/pfr match — only nfl_id.
    found = Nflverse::SeedPlayers.new(csv_body: csv, upload_headshots: false)
                                 .send(:lookup_athlete_by_ids, gsis_id: nil, pff_id: nil, otc_id: nil,
                                                               espn_id: nil, pfr_id: nil, nflverse_id: "NFL-123")

    assert_equal athlete.id, found&.id, "nflverse_id must be part of the lookup hierarchy"
  end

  test "re-importing the same feed twice does not wedge on the unique index" do
    body = csv(row(gsis: "00-0036442", nfl_id: "NFL-123"))
    import(body)

    assert_nothing_raised { import(body) }
    assert_equal 1, Athlete.where(nflverse_id: "NFL-123").count
  end

  # --- the ship-aborter ---------------------------------------------------

  test "a feed outage is reported and does NOT raise" do
    importer = Nflverse::SeedPlayers.new(upload_headshots: false)
    importer.define_singleton_method(:fetch_remote) do
      raise Nflverse::SeedPlayers::FeedUnavailable, "OpenURI::HTTPError: 404 Not Found"
    end

    stats = nil
    assert_nothing_raised { stats = importer.call }
    assert_equal 1, stats[:feed_unavailable],
                 "a third-party outage must not abort bin/release's ship"
  end

  test "a feed outage still leaves a failed run on the record" do
    importer = Nflverse::SeedPlayers.new(upload_headshots: false)
    importer.define_singleton_method(:fetch_remote) do
      raise Nflverse::SeedPlayers::FeedUnavailable, "SocketError: down"
    end
    importer.call

    run = ImportRun.for_source("nflverse_players").order(:id).last
    assert_equal "failed", run.status,
                 "non-fatal must not mean invisible — the stale data has to be discoverable"
    assert_match(/SocketError/, run.detail)
  end

  # A REAL import defect must still abort, or the non-fatal path would hide
  # every genuine failure behind the same silence.
  test "an ordinary error still raises" do
    importer = Nflverse::SeedPlayers.new(upload_headshots: false)
    importer.define_singleton_method(:fetch_remote) { raise ArgumentError, "our bug" }

    assert_raises(ArgumentError) { importer.call }
  end

  test "a successful import records an ok run" do
    import(csv(row(gsis: "00-0036442", nfl_id: "NFL-123")))

    assert_equal "ok", ImportRun.last_success_for("nflverse_players").status
  end
end
