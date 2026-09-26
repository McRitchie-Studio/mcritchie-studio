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
    @env_was = ENV.to_h.slice("SEASON", "GRADES_FROM", "TEAM", "VERBOSE",
                              "HEADSHOT_PAUSE", "HEADSHOT_LIMIT")
    # The task sleeps between ATTEMPTED uploads to stay a polite guest at
    # a.espncdn.com. Nothing here talks to ESPN, so the suite does not pay for
    # the politeness — but it is set explicitly rather than left to the default,
    # so a future change to that default cannot quietly add seconds per test.
    ENV["HEADSHOT_PAUSE"] = "0"
    ENV.delete("HEADSHOT_LIMIT")
  end

  teardown do
    %w[SEASON GRADES_FROM TEAM VERBOSE HEADSHOT_PAUSE HEADSHOT_LIMIT].each { |k| ENV.delete(k) }
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

  # --- nfl:upload_headshots: the work it declined to do ---------------------
  #
  # [integration] The verdicts above grade the ATTEMPTS. These grade whether the
  # run attempted anything at all — a different question, and the one that cost
  # 2,048 athletes their avatar.

  # THE DEFECT, MEASURED ON PRODUCTION 2026-09-26. The task resolved an NFL team
  # through person.contracts and `next`-ed past any athlete without one:
  # `candidates: 2048`, `cached: 0`, `skipped (no NFL team): 2048`, exit 0. Both
  # `contracts` and `teams` are EMPTY tables in production — 0 rows each — so
  # that precondition could not be satisfied by anybody, and the task had cached
  # nothing, ever, while printing a clean summary. The team is a folder name.
  test "the headshot upload caches an athlete with no contract at all" do
    athlete = headshot_candidate(1, team_slug: "buffalo-bills")
    assert_empty athlete.person.contracts,
                 "precondition: the production shape — an athlete with a team_slug and no contract"

    keys = []
    capture_io do
      Studio::ImageCache.stub(:cache!, ->(key_prefix:, **) { keys << key_prefix; {} }) do
        Rake::Task["nfl:upload_headshots"].invoke
      end
    end

    assert_equal ["headshots/nfl/buffalo-bills/#{athlete.person_slug}"], keys,
                 "a contract is not a precondition for a headshot, and the athlete's own " \
                 "team_slug is where the folder comes from"
  end

  # The other half of the fallback: no team at all is still an upload.
  test "the headshot upload caches a teamless athlete under free-agents" do
    athlete = headshot_candidate(2, team_slug: nil)

    keys = []
    capture_io do
      Studio::ImageCache.stub(:cache!, ->(key_prefix:, **) { keys << key_prefix; {} }) do
        Rake::Task["nfl:upload_headshots"].invoke
      end
    end

    assert_equal ["headshots/nfl/free-agents/#{athlete.person_slug}"], keys
  end

  # THE SILENT SUCCESS ITSELF. `failed > cached` is structurally blind here —
  # both counters are 0, so the rule is false and the task returns normally. A
  # run that finds work and attempts none of it is the task refusing its job, not
  # S3 refusing the upload, and it must not exit 0.
  test "the headshot upload refuses a run that attempted none of the work it found" do
    headshot_candidate(3, espn_headshot_url: nil)
    headshot_candidate(4, espn_headshot_url: nil)

    _out, err = capture_io do
      assert_raises(SystemExit) { Rake::Task["nfl:upload_headshots"].invoke }
    end

    assert_match(/attempted 0 of the 2 athletes/, err)
    assert_match(/declined every one of them WITHOUT trying/, err)
    assert_match(/espn_headshot_url/, err, "name the field an operator goes and fills")
  end

  # THE GREEN TWIN THAT KEEPS THE GUARD HONEST, and the reason it is computed
  # from `needed` rather than from `cached`. On a warm machine nearly every
  # candidate is already complete; a rule that reddened THAT run would be a rule
  # an operator switches off, which is how the ecosystem got here.
  test "a warm re-run with every headshot already cached stays green and says nothing" do
    athlete = headshot_candidate(5, team_slug: "buffalo-bills")
    cache_variants(athlete, %w[original 100 400])

    completed = false
    _out, err = capture_io do
      Studio::ImageCache.stub(:cache!, ->(**) { flunk "a complete athlete must not be re-uploaded" }) do
        Rake::Task["nfl:upload_headshots"].invoke
        completed = true
      end
    end

    assert completed, "nothing left to do is not a failure"
    assert_equal "", err, "the warm re-run legitimately attempts nothing — `needed` subtracts " \
                          "the complete candidates out precisely so this stays silent"
  end

  # A PARTIAL decline is reported, not refused. Some athletes have no image
  # source and never will; reddening a rebuild for a permanent data gap trains an
  # operator to stop reading the line.
  test "a partial decline is reported without reddening the run" do
    headshot_candidate(6, team_slug: "buffalo-bills")
    headshot_candidate(7, espn_headshot_url: nil)

    completed = false
    _out, err = capture_io do
      Studio::ImageCache.stub(:cache!, ->(**) { {} }) do
        Rake::Task["nfl:upload_headshots"].invoke
        completed = true
      end
    end

    assert completed, "one athlete with no source URL is a data gap, not a broken uploader"
    assert_match(/1 of 2 athletes needing a headshot were skipped without an attempt/, err)
  end

  # "ALREADY DONE" HAS TO INCLUDE "original". Studio::ImageCache.cache! stores
  # the unmodified source plus one variant per width, so a row set holding only
  # 100 and 400 is NOT done — and calling it done both hides the gap and inflates
  # `skipped_complete`, which is the denominator the verdict above is computed
  # from. upload_coach_headshots already spelled its check this way.
  test "an athlete missing only the original is not already done" do
    athlete = headshot_candidate(8, team_slug: "buffalo-bills")
    cache_variants(athlete, %w[100 400])

    attempts = 0
    capture_io do
      Studio::ImageCache.stub(:cache!, ->(**) { attempts += 1; {} }) do
        Rake::Task["nfl:upload_headshots"].invoke
      end
    end

    assert_equal 1, attempts,
                 "100 and 400 without an original is an incomplete row set, not a finished one"
  end

  # RESUMABILITY, the operable half. A cold run is ~2,000 fetches from
  # a.espncdn.com plus three S3 puts each, which an operator wants to take in
  # waves and inspect between. Nothing records progress because nothing has to:
  # the ImageCache rows ARE the progress, so the next wave resumes exactly where
  # this one stopped.
  test "HEADSHOT_LIMIT stops the run after N attempted uploads" do
    3.times { |i| headshot_candidate(20 + i, team_slug: "buffalo-bills") }
    ENV["HEADSHOT_LIMIT"] = "2"

    attempts = 0
    completed = false
    capture_io do
      Studio::ImageCache.stub(:cache!, ->(**) { attempts += 1; {} }) do
        Rake::Task["nfl:upload_headshots"].invoke
        completed = true
      end
    end

    assert completed, "a bounded wave is a complete run, not a partial failure"
    assert_equal 2, attempts, "the limit bounds the ATTEMPTS, which is the cost being bounded"
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
  # A CANDIDATE IN THE PRODUCTION SHAPE: espn_id set, a team_slug on the athlete's
  # OWN column, and no Contract anywhere. prepare_candidates above deliberately
  # picks NFL-CONTRACTED people because that is what the task used to demand; this
  # builds the athlete the task used to throw away.
  def headshot_candidate(suffix, team_slug: nil, espn_headshot_url: :espn)
    person = Person.create!(first_name: "Head", last_name: "Shot#{suffix}", athlete: true)
    url = if espn_headshot_url == :espn
      "https://a.espncdn.com/i/headshots/nfl/players/full/9#{suffix}.png"
    else
      espn_headshot_url
    end
    Athlete.create!(person_slug: person.slug, sport: "football", team_slug: team_slug,
                    espn_id: "9#{suffix}", espn_headshot_url: url)
  end

  def cache_variants(athlete, variants)
    variants.each do |variant|
      ImageCache.create!(owner: athlete, purpose: "headshot", variant: variant,
                         s3_key: "#{athlete.headshot_key_prefix}/#{variant}.png",
                         content_type: "image/png")
    end
    athlete.reload
  end

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
