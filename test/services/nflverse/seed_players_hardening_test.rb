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

  # THE REGRESSION THIS BUG OWES. The previous version carried a gsis_id, so
  # lookup_athlete_by_ids returned at the FIRST probe and the test passed with
  # or without the nflverse_id fix — it exercised nothing.
  #
  # Here the second row shares NOTHING but nflverse_id, which is uniquely
  # indexed. Without the fix it falls through to the name path, update! raises
  # into the caller's rescue, and the athlete is left with no league IDs.
  test "a row matching only on nflverse_id updates rather than colliding" do
    import(csv(row(gsis: "00-0036442", nfl_id: "NFL-123")))
    assert_equal 1, Athlete.where(nflverse_id: "NFL-123").count

    # Same human, arriving with a DIFFERENT gsis and no other shared id.
    second = "00-0099999,9999999,,,,NFL-123,Joe,Joe,Burrow,QB,CIN,ACT,2026,76,215"
    assert_nothing_raised { import(csv(second)) }

    assert_equal 1, Athlete.where(nflverse_id: "NFL-123").count,
                 "nflverse_id is uniquely indexed — a second row must update, not fork"
  end

  # --- the ship-aborter ---------------------------------------------------
  #
  # THESE NOW FAIL THE SOURCE, not the wrapper. The previous versions stubbed
  # fetch_remote to raise FeedUnavailable directly, which proved `call` HANDLES
  # it and never that fetch_remote RAISES it — the rescue clause, the entire
  # subject of the change, had zero coverage. Every class below was measured
  # uncovered by the earlier literal list.

  def importer_whose_network_raises(error)
    imp = Nflverse::SeedPlayers.new(upload_headshots: false)
    imp.define_singleton_method(:open_source) { |_url| raise error }
    imp
  end

  {
    "a server that hangs up mid-chunk" => EOFError.new("end of file reached"),
    "a connection timeout"             => Errno::ETIMEDOUT.new,
    "an unreachable network"           => Errno::ENETUNREACH.new,
    "a broken pipe"                    => Errno::EPIPE.new,
    "a refused connection"             => Errno::ECONNREFUSED.new,
    "a DNS failure"                    => SocketError.new("getaddrinfo"),
    "a read timeout"                   => Net::ReadTimeout.new,
    "a TLS failure"                    => OpenSSL::SSL::SSLError.new("handshake")
  }.each do |label, error|
    test "#{label} becomes FeedUnavailable rather than aborting the ship" do
      imp = importer_whose_network_raises(error)

      assert_raises(Nflverse::SeedPlayers::FeedUnavailable) { imp.send(:fetch_remote) }
      assert_nothing_raised { imp.call }
    end
  end

  # PLAYERS_URL is a GitHub release download, so EVERY fetch redirects — this
  # path is live, and open-uri signals it with a BARE RuntimeError.
  test "an open-uri redirect refusal becomes FeedUnavailable" do
    imp = importer_whose_network_raises(RuntimeError.new("redirection forbidden: http://a -> https://b"))

    assert_raises(Nflverse::SeedPlayers::FeedUnavailable) { imp.send(:fetch_remote) }
  end

  test "an open-uri redirect loop becomes FeedUnavailable" do
    imp = importer_whose_network_raises(RuntimeError.new("HTTP redirection loop: http://a"))

    assert_raises(Nflverse::SeedPlayers::FeedUnavailable) { imp.send(:fetch_remote) }
  end

  # The quiet path must not swallow OUR bugs. A bare RuntimeError that is not a
  # redirect refusal has to keep raising.
  test "an unrelated RuntimeError still raises" do
    imp = importer_whose_network_raises(RuntimeError.new("our bug"))

    assert_raises(RuntimeError) { imp.send(:fetch_remote) }
  end

  test "a feed outage still leaves a failed run on the record" do
    importer_whose_network_raises(SocketError.new("down")).call

    run = ImportRun.for_source("nflverse_players").order(:id).last
    assert_equal "failed", run.status,
                 "non-fatal must not mean invisible — the stale data has to be discoverable"
  end

  test "an ordinary error still raises" do
    imp = Nflverse::SeedPlayers.new(upload_headshots: false)
    imp.define_singleton_method(:open_source) { |_url| raise ArgumentError, "our bug" }

    assert_raises(ArgumentError) { imp.call }
  end

  test "a successful import records an ok run" do
    import(csv(row(gsis: "00-0036442", nfl_id: "NFL-123")))

    assert_equal "ok", ImportRun.last_success_for("nflverse_players").status
  end
end
