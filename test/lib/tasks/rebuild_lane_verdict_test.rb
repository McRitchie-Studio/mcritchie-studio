require "test_helper"
require "rake"

# [integration] The three rebuild-lane rake tasks that could not fail, run for
# real against the DB.
#
# THE COMPANION TO THE PHASE TESTS, WHICH CANNOT ASK THIS. test/lib/ecosystem_
# build_*_verdict_test.rb stub `bundle` and prove the PHASE reacts to an exit
# code. That is the wiring half. This file is the other half: whether the task
# ever produces a non-zero exit code to react to. Both were broken, and either
# one alone reads as fixed.
#
# Each task here rescues a per-item failure on purpose — one dead ESPN team must
# not cost the other 31 their refresh, one dead headshot URL must not cost the
# other thousand theirs — and then ended by returning, so the process exited 0
# no matter how much had failed. The rescue is right; ending on it was not.
class RebuildLaneVerdictTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("espn:scrape_depth_charts")
    %w[espn:scrape_depth_charts nfl:upload_headshots nfl:rankings_compute].each do |name|
      Rake::Task[name].reenable
    end
    @env_was = ENV.to_h.slice("SEASON", "GRADES_FROM", "TEAM", "VERBOSE")
  end

  teardown do
    %w[SEASON GRADES_FROM TEAM VERBOSE].each { |k| ENV.delete(k) }
    @env_was.each { |k, v| ENV[k] = v }
  end

  # --- espn:scrape_depth_charts -------------------------------------------

  # MEASURED BEFORE THE FIX, with fetch_groups stubbed to nil for all 32 teams:
  # the task printed `{:teams_failed=>32}` and exited 0.
  test "the depth chart scrape refuses a run that applied no teams" do
    _out, err = capture_io do
      assert_raises(SystemExit) { scrape(teams_failed: 32) }
    end

    assert_match(/applied 0 of 32 teams/, err)
    assert_match(/did not happen/i, err)
  end

  # THE GREEN TWIN, differing by exactly one team. A guard that refused every
  # run would pass the case above and is caught here.
  test "the depth chart scrape accepts a run that applied one team" do
    completed = false
    capture_io { scrape(teams_scraped: 1, teams_failed: 31); completed = true }

    assert completed, "one applied team is a bad afternoon, not a scrape that never " \
                      "happened — a guard that refuses it is a guard operators switch off"
  end

  # A PARTIAL RUN IS REPORTED, NOT REFUSED. One dead team is a normal ESPN
  # afternoon; a lane that goes red on it is a lane an operator learns to
  # ignore. The degradation still has to be legible, so it goes to stderr, which
  # the rebuild lane no longer discards.
  test "a partial scrape stays green but says how many teams it lost" do
    _out, err = capture_io { scrape(teams_scraped: 1, teams_failed: 30, teams_partial: 1) }

    assert_match(/1 of 32 teams applied/, err)
    assert_match(/30 failed, 1 partial/, err)
  end

  # A CLEAN RUN SAYS NOTHING. The summary is a signal, and a signal printed on
  # every healthy run is not one.
  test "a clean scrape prints no tally at all" do
    _out, err = capture_io { scrape(teams_scraped: 32) }

    assert_equal "", err
  end

  # The single-team form (TEAM=buf) has to be gradeable too — its whole run is
  # one team, so a failure there is a total failure, not a 1-in-32 blip.
  test "a single-team scrape that fails is a total failure" do
    ENV["TEAM"] = "buf"
    _out, err = capture_io do
      assert_raises(SystemExit) { scrape(teams_failed: 1) }
    end

    assert_match(/applied 0 of 1 teams/, err)
  end

  # --- nfl:upload_headshots ------------------------------------------------

  # MEASURED BEFORE THE FIX with the real Aws::Errors::MissingCredentialsError
  # raised from Studio::ImageCache.cache!: candidates 3, failed 3, cached 0,
  # exit 0 — a credential failure reported as a success.
  test "the headshot upload refuses a run where every upload failed" do
    prepare_candidates(2)

    _out, err = capture_io do
      Studio::ImageCache.stub(:cache!, ->(**) { raise Aws::Errors::MissingCredentialsError, "no creds" }) do
        assert_raises(SystemExit) { Rake::Task["nfl:upload_headshots"].invoke }
      end
    end

    assert_match(/failed 2 of 2 attempted uploads/, err)
    assert_match(/AWS_ACCESS_KEY_ID/, err, "name the credential an operator goes and checks")
  end

  # THE GREEN TWIN, AND THE REASON THE RULE IS A MAJORITY RULE. A single dead
  # source URL among many is a normal afternoon; reddening a whole rebuild for
  # it trains an operator to stop reading the line.
  test "the headshot upload accepts a run where one upload of three failed" do
    people = prepare_candidates(3)
    doomed = people.first

    completed = false
    capture_io do
      Studio::ImageCache.stub(:cache!, ->(owner:, **) {
        raise Aws::Errors::MissingCredentialsError, "no creds" if owner.person_slug == doomed
        {}
      }) do
        Rake::Task["nfl:upload_headshots"].invoke
        completed = true
      end
    end

    assert completed, "1 failure against 2 successes is one dead source URL, not a " \
                      "broken uploader — refusing it would red a whole rebuild for a 404"
  end

  # NOTHING TO DO IS NOT A FAILURE. With no candidate the counters are 0 and 0,
  # and `failed > cached` must not fire on a tie at zero — the first reading of
  # this task on a desk was exactly this, "candidates: 0", and it is the vacuous
  # green a guard must not mistake for a real one.
  test "the headshot upload accepts a run with nothing to upload" do
    assert_equal 0, Athlete.where.not(espn_id: nil).count,
                 "precondition: no candidates, which is the state that produced the " \
                 "first vacuous green reading of this task on a desk"

    completed = false
    capture_io { Rake::Task["nfl:upload_headshots"].invoke; completed = true }

    assert completed, "`failed > cached` must not fire on a tie at zero — nothing to " \
                      "do is not a failure"
  end

  # --- nfl:rankings_compute ------------------------------------------------

  # MEASURED BEFORE THE FIX: with AthleteGrade emptied, compute_all! wrote the
  # SAME 448 rows a healthy run writes and exited 0 — 448 scores of 0.0 where
  # the healthy run spans 442 distinct values from 49.6 to 5604.37. The row
  # count the rebuild lane logs is identical in both worlds; only the scores
  # differ, so the scores are where the verdict has to be read.
  test "the ranking compute refuses a ranking where every team scored zero" do
    TeamRanking.where(season_slug: "2025-nfl").delete_all
    AthleteGrade.delete_all
    ENV["SEASON"] = "2025-nfl"
    ENV["GRADES_FROM"] = "2025-nfl"

    _out, err = capture_io do
      assert_raises(SystemExit) { Rake::Task["nfl:rankings_compute"].invoke }
    end

    assert_match(/scored every team 0\.0/, err)
    assert_match(/2025-nfl has no AthleteGrade rows/, err)
    assert_match(/GRADES_FROM/, err, "name the knob that fixes it")
  end

  # THE GREEN TWIN, differing by exactly the presence of the grade rows.
  test "the ranking compute accepts a ranking with a spread of scores" do
    TeamRanking.where(season_slug: "2025-nfl").delete_all
    ENV["SEASON"] = "2025-nfl"
    ENV["GRADES_FROM"] = "2025-nfl"

    completed = false
    capture_io { Rake::Task["nfl:rankings_compute"].invoke; completed = true }

    assert completed, "a ranking with a real spread must not be refused"
    scores = TeamRanking.where(season_slug: "2025-nfl").pluck(:score).compact
    assert scores.any?(&:positive?),
           "precondition: the fixtures must produce a real ranking, or the case above " \
           "is not distinguishable from this one"
  end

  private

  # NOTE the lambda. Minitest's `stub` CALLS a value that responds to `call`, so
  # handing it the service double directly would invoke the double's own `call`
  # with `new`'s keyword arguments and hand the task a tally where it expects a
  # service. The lambda absorbs `new`'s arguments and returns the double.
  def scrape(**tally)
    stats = Hash.new(0).merge(tally)
    fake = Object.new
    fake.define_singleton_method(:call) { stats }
    Espn::ScrapeDepthCharts.stub(:new, ->(**) { fake }) do
      Rake::Task["espn:scrape_depth_charts"].invoke
    end
  end

  # Athletes the task will actually attempt: an espn_id, an NFL-league team
  # through a contract, and no cached variants yet.
  def prepare_candidates(count)
    people = Person.joins("INNER JOIN contracts ON contracts.person_slug = people.slug")
                   .joins("INNER JOIN teams ON teams.slug = contracts.team_slug AND teams.league = 'nfl'")
                   .distinct.limit(count).pluck(:slug)
    assert_equal count, people.size, "fixtures did not supply #{count} NFL-contracted people"

    people.each_with_index do |slug, i|
      athlete = Athlete.find_by(person_slug: slug) || Athlete.create!(person_slug: slug, sport: "football")
      athlete.update!(espn_id: "8800#{i}",
                      espn_headshot_url: "https://a.espncdn.com/i/headshots/nfl/players/full/8800#{i}.png")
      ImageCache.where(owner: athlete, purpose: "headshot").destroy_all
    end
    people
  end
end
