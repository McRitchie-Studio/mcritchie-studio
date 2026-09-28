require "test_helper"
require "rake"
# THE FETCH LIBRARY THE LANE ACTUALLY USES. Studio::ImageCache.fetch_remote calls
# `URI.open`, so a retired ESPN headshot reaches the task as an
# OpenURI::HTTPError. Required here because `dead_source_error` below builds the
# genuine object rather than a double that would pass a weaker check.
require "open-uri"
require "stringio"
# MEASURED 2026-09-27: WITHOUT THIS, `Aws` IS UNDEFINED IN THIS PROCESS. The
# Gemfile carries `gem "aws-sdk-s3", require: false` and the one place the app
# loads it is Studio::S3, which every stub below replaces. So every case here that
# documented itself as raising "the real Aws::Errors::MissingCredentialsError" was
# in fact raising a NameError, and passed because it only ever asserted on counts
# and on the abort's own wording. The verdicts now print the exception CLASS, which
# is what exposed it. Required so the cases mean what they say.
require "aws-sdk-s3"

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
#
# THREE IS THIS FILE'S COVERAGE, NOT THE REPOSITORY'S INVENTORY. Two more lanes of
# the same shape were closed under `coach-link-lane-false-green` (2026-09-28) and
# live in test/lib/tasks/nfl_coach_headshots_test.rb and
# test/lib/tasks/nfl_coach_team_sites_test.rb, because they sit in a different phase:
# they are reached only through `db:seed` and db/seeds/32_headshot_links.rb, not
# through 6b or 6c. `nfl:upload_coach_headshots` is the one still ungraded —
# it counts `failed` and prints it, and it needs the dead-source split
# nfl:upload_headshots carries. Known open, not measured clean.
class RebuildLaneVerdictTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("espn:scrape_depth_charts")
    %w[espn:scrape_depth_charts nfl:upload_headshots nfl:rekey_headshots nfl:rankings_compute].each do |name|
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

  # A REFUSAL NOBODY CAN FIND LATER IS HALF A REFUSAL. `abort` writes to stderr and
  # raises SystemExit; bin/ecosystem-build turns that into one `log_fail` line in a
  # build log nobody keeps, and nothing durable recorded that the scrape did not
  # happen. MEASURED on this branch's parent: zero ErrorLog references anywhere in
  # app/services/espn/ or lib/tasks/espn.rake.
  test "the depth chart scrape files an ErrorLog before it refuses the run" do
    assert_difference -> { ErrorLog.count }, 1 do
      capture_io { assert_raises(SystemExit) { scrape(teams_failed: 32) } }
    end

    row = ErrorLog.order(:id).last
    assert_match(/ScrapeDidNotHappen/, row.inspect_field)
    assert_match(/applied 0 of 32 teams/, row.message)
    assert row.backtrace.present? && row.backtrace != "[]",
           "raised and rescued rather than constructed, so the row carries a real backtrace"
    assert row.slug.present?, "a row with no slug is unreachable in /admin/error_logs"
  end

  # THE GREEN TWINS. A partial run stays green AND stays unfiled: the `warn` reports
  # it and the service already filed a row per dead team, so a second row for the
  # tally would be one more spelling of facts already on file.
  test "a partial scrape files no lane row" do
    assert_no_difference -> { ErrorLog.count } do
      capture_io { scrape(teams_scraped: 1, teams_failed: 31) }
    end
  end

  test "a clean scrape files no lane row" do
    assert_no_difference -> { ErrorLog.count } do
      capture_io { scrape(teams_scraped: 32) }
    end
  end

  # A RAISE OUT OF THE SERVICE — an unreadable teams index, or a MissingTeamId
  # escaping the per-team rescue — is the loudest failure and was the least findable:
  # a backtrace on stderr and nothing in /admin/error_logs. Filed and RE-RAISED, so
  # the lane still goes red.
  test "a raise out of the service is filed and still kills the lane" do
    assert_difference -> { ErrorLog.count }, 1 do
      assert_raises(Espn::ScrapeDepthCharts::SourceUnavailable) { scrape_raising }
    end

    assert_match(/teams index/, ErrorLog.order(:id).last.message)
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

  # THE MINORITY FAILURE REACHES THE CHANNEL THE REBUILD LANE READS. The majority
  # rule is structurally quiet here and should be — one failure against two
  # successes is not the uploader breaking. But before this the ONLY trace was a
  # [!] line on stdout and a `failed: 1` counter, and the lane reads stderr: a
  # credential revoked at athlete 1,900 of 2,043 exits 0 with 143 unread failures.
  # A warning, never an abort, for the reason the twin above exists.
  test "a minority of failed uploads warns without reddening the run" do
    people = prepare_candidates(3)
    doomed = people.first

    _out, err = capture_io do
      Studio::ImageCache.stub(:cache!, ->(owner:, **) {
        raise Aws::Errors::MissingCredentialsError, "no creds" if owner.person_slug == doomed
        {}
      }) do
        refute_aborts { Rake::Task["nfl:upload_headshots"].invoke }
      end
    end

    assert_match(/failed 1 of 3 attempted uploads/, err)
    # THIS USED TO DEMAND THE WARNING SAY "dead ESPN source URL", which was the
    # conflation this task exists to undo: the warning GUESSED that a minority
    # failure was probably a 404, because a 404 could reach this counter. It cannot
    # any more — dead sources are classified off the exception and counted
    # separately — so whatever is in here is ours or a transient, and the warning
    # says which by naming the actual cause instead of guessing at a category.
    assert_match(/Causes: #{doomed}: Aws::Errors::MissingCredentialsError/, err,
                 "the cause an operator acts on, not a guess at which party is at fault")
    refute_match(/dead ESPN source URL/, err,
                 "a dead source cannot reach this counter, so naming one here would send " \
                 "the operator to look at ESPN for a failure that is ours")
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
        refute_aborts { Rake::Task["nfl:upload_headshots"].invoke }
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
        refute_aborts { Rake::Task["nfl:upload_headshots"].invoke }
      end
    end

    assert_equal ["headshots/nfl/free-agents/#{athlete.person_slug}"], keys
  end

  # THE FALSE ABORT, AT ITS SMALLEST — and this test used to ASSERT it. Neither
  # athlete here has an `espn_headshot_url`, so NO run can ever fetch either one,
  # and the verdict that fired accused the LANE of declining them. A VERDICT MUST
  # BE CLEARABLE BY FIXING WHAT IT ACCUSES: this one could only be cleared by
  # populating a column the lane does not write, which is why it fired for ever.
  # The decline rule's population now holds only athletes a source could have
  # answered for, and the permanently sourceless are reported BY NAME instead.
  test "athletes with no source URL are named in the report, never aborted on" do
    a = headshot_candidate(3, espn_headshot_url: nil)
    b = headshot_candidate(4, espn_headshot_url: nil)

    out, err = capture_io do
      refute_aborts { Rake::Task["nfl:upload_headshots"].invoke }
    end

    assert_match(/no espn_headshot_url:\s+2/, out)
    assert_match(/#{a.person_slug}/, out, "name the athlete an operator goes and fixes")
    assert_match(/#{b.person_slug}/, out)
    assert_match(/nfl:players_seed/, out, "name the task that can fill the column")
    assert_equal "", err, "a permanent data gap is inventory, not an alert — a line printed " \
                          "on every healthy run is a line an operator stops reading"
  end

  # THE GREEN TWIN THAT KEEPS THE GUARD HONEST, and the reason the rule is
  # computed from a POPULATION rather than from `cached`. On a warm machine nearly
  # every candidate is already complete; a rule that reddened THAT run would be a
  # rule an operator switches off, which is how the ecosystem got here. This twin
  # passed throughout the false abort below, because its population is ONE
  # complete athlete and production's carries a permanent residue too.
  test "a warm re-run with every headshot already cached stays green and says nothing" do
    athlete = headshot_candidate(5, team_slug: "buffalo-bills")
    cache_variants(athlete, %w[original 100 400])

    completed = false
    _out, err = capture_io do
      Studio::ImageCache.stub(:cache!, ->(**) { flunk "a complete athlete must not be re-uploaded" }) do
        refute_aborts { Rake::Task["nfl:upload_headshots"].invoke }
        completed = true
      end
    end

    assert completed, "nothing left to do is not a failure"
    assert_equal "", err, "the warm re-run legitimately attempts nothing — the decline rule's " \
                          "population subtracts the complete candidates out so this stays silent"
  end

  # A SOURCELESS ATHLETE IS INVENTORY, NOT A VERDICT — the property the decline
  # rule's narrowing buys, asserted where a warm re-run can see it. The twin above
  # holds only because its whole population is one complete athlete; this one adds
  # the shape that used to abort.
  #
  # ITS PREMISE, RE-MEASURED ON PRODUCTION 2026-09-27, AND CORRECTED. This comment
  # used to say production carried 2,043 complete PLUS EIGHT with no
  # `espn_headshot_url`, which kept `needed` positive against `attempted` 0 so the
  # healthy re-run aborted. The eight athletes are real — they are the ones short a
  # variant — but they are TWO populations and only one of them is a candidate:
  #
  #   chris-manhertz brandon-scherff jack-plummer jack-strand brett-thorson
  #     espn_id yes, espn_headshot_url yes -> CANDIDATE, FETCHABLE, source 404s
  #   james-thompson gabe-rubio blake-miller
  #     espn_id NO, espn_headshot_url NO   -> not a candidate at all
  #
  # So `skipped_no_source` is ZERO on production and this rule never fired there.
  # The abort operators actually got was `failed > cached` on five 404s, which is
  # what the dead-source tests below cover. This shape is still worth pinning: the
  # column is nullable, a cold run before any seed has thousands of them, and the
  # rule must be quiet as a property of its population rather than by luck.
  test "a warm re-run with a permanently sourceless athlete stays green" do
    complete = headshot_candidate(30, team_slug: "buffalo-bills")
    cache_variants(complete, %w[original 100 400])
    sourceless = headshot_candidate(31, espn_headshot_url: nil)

    out, err = capture_io do
      Studio::ImageCache.stub(:cache!, ->(**) { flunk "nothing in this population is fetchable" }) do
        refute_aborts { Rake::Task["nfl:upload_headshots"].invoke }
      end
    end

    assert_equal "", err, "every cachable headshot IS cached — this is the healthy steady " \
                          "state, and a rebuild that reddens on it trains an operator to " \
                          "ignore a red rebuild"
    assert_match(/#{sourceless.person_slug}/, out,
                 "the permanent residue is reported by name, which is the honest way to ask " \
                 "for the data to be fixed")
  end

  # A MIXED RUN FETCHES WHAT IT CAN AND NAMES WHAT IT CANNOT. This used to assert
  # a stderr line calling the sourceless athlete "skipped without an attempt",
  # which reads as work the lane declined. It is not: there was nothing to attempt.
  # The distinction is the whole fix — a gap at the SOURCE step is a data gap and
  # belongs in the report, and only a gap at the RESULT step grades the lane.
  test "a mixed run fetches what it can and names what it cannot" do
    fetched = headshot_candidate(6, team_slug: "buffalo-bills")
    gap = headshot_candidate(7, espn_headshot_url: nil)

    attempts = []
    out, err = capture_io do
      Studio::ImageCache.stub(:cache!, ->(owner:, **) { attempts << owner.person_slug; {} }) do
        refute_aborts { Rake::Task["nfl:upload_headshots"].invoke }
      end
    end

    assert_equal [fetched.person_slug], attempts,
                 "the athlete WITH a source is still fetched — narrowing the graded " \
                 "population must not narrow the work"
    assert_match(/#{gap.person_slug}/, out, "the one without a source is named, not graded")
    assert_equal "", err, "one athlete with no source URL is a data gap, not a broken uploader"
  end

  # THE RULE THAT MUST SURVIVE THE NARROWING, and the reason this is a separate
  # test rather than a line in the one above. Narrowing the decline rule's
  # population is only safe if the OTHER verdict still sees a wholesale failure,
  # so this run carries the permanent residue AND a dead uploader at once: the
  # sourceless athlete must not dilute the credential verdict, which grades the
  # attempts and nothing else.
  test "a wholesale upload failure still exits non-zero beside sourceless athletes" do
    headshot_candidate(32, team_slug: "buffalo-bills")
    headshot_candidate(33, team_slug: "buffalo-bills")
    headshot_candidate(34, espn_headshot_url: nil)

    _out, err = capture_io do
      Studio::ImageCache.stub(:cache!, ->(**) { raise Aws::Errors::MissingCredentialsError, "no creds" }) do
        assert_raises(SystemExit) { Rake::Task["nfl:upload_headshots"].invoke }
      end
    end

    assert_match(/failed 2 of 2 attempted uploads/, err,
                 "the athlete with no source was never attempted, so it is not in this " \
                 "denominator — a data gap must not dilute a credential failure")
    assert_match(/AWS_ACCESS_KEY_ID/, err)
  end

  # --- nfl:upload_headshots: a dead SOURCE is not a broken UPLOADER ---------
  #
  # [integration] A 404 from a.espncdn.com is a fact about ESPN; a failed
  # `put_object` is a fact about us. The task counted both in one `failed`
  # counter through one bare `rescue => e`, so the rule `failed > cached` fired on
  # a run where nothing was wrong with the uploader, and the abort's first named
  # cause was "usually AWS credentials".

  # THE DEFECT, MEASURED ON PRODUCTION 2026-09-27 (read-only, heroku run
  # bin/rails runner):
  #
  #   TOTAL=2051  WITH_ESPN_ID=2048  COMPLETE_CANDIDATES=2043
  #   FETCHABLE=5  SOURCELESS_CANDIDATES=0
  #
  # So production's whole fetchable population is five athletes, every one of them
  # WITH an `espn_headshot_url` on file, and every one of those five URLs answers
  # 404 when fetched the way the app fetches — `URI.open(url, read_timeout: 30,
  # redirect: true)` — while a control espn_id answered 230,577 bytes through the
  # same call. `curl` agreeing proves nothing about what Ruby sees, so it was
  # asked in Ruby.
  #
  # The run is therefore cached 0, failed 5, and `failed > cached` aborts the
  # rebuild and tells the operator to check AWS credentials that are fine. Scaled
  # to 2 here, which is the same shape: 100% of attempts "failed", none of them
  # ours. THIS IS NOT A REGRESSION FROM THE `fetchable` NARROWING — the retired
  # `needed` code aborted identically on the same data, by the same rule.
  test "a run whose every ESPN source answers 404 stays green and names them" do
    a = headshot_candidate(40, team_slug: "buffalo-bills")
    b = headshot_candidate(41, team_slug: "buffalo-bills")

    out, err = capture_io do
      Studio::ImageCache.stub(:cache!, ->(**) { raise dead_source_error }) do
        refute_aborts { Rake::Task["nfl:upload_headshots"].invoke }
      end
    end

    assert_equal "", err, "a retired ESPN photo is a data gap, exactly like a blank " \
                          "espn_headshot_url — the uploader did its job and there was " \
                          "nothing at the other end. Only OUR failure may redden a run"
    assert_match(/dead source \(404\/410\):\s+2/, out)
    assert_match(/failed:\s+0/, out,
                 "a 404 must leave the graded counter untouched, not merely be excused " \
                 "afterwards — a subtraction cannot tell the two apart")
    assert_match(/#{a.person_slug}/, out, "name the athlete an operator goes and checks")
    assert_match(/#{b.person_slug}/, out)
    assert_match(/HTTP 404/, out, "carry the status, because 404 is permanent and 503 is not")
  end

  # THE GUARD THAT MUST SURVIVE THE SPLIT, and the reason it is a separate test.
  # Taking 404s out of `failed` is only safe if a REAL wholesale failure still
  # reddens — otherwise this fix trades one silent success for another, which is
  # the defect the majority rule was written to catch in the first place.
  test "a wholesale upload failure still exits non-zero beside dead sources" do
    headshot_candidate(42, team_slug: "buffalo-bills")
    headshot_candidate(43, team_slug: "buffalo-bills")
    doomed = headshot_candidate(44, team_slug: "buffalo-bills").person_slug

    _out, err = capture_io do
      Studio::ImageCache.stub(:cache!, ->(owner:, **) {
        raise Aws::Errors::MissingCredentialsError, "no creds" unless owner.person_slug == doomed
        raise dead_source_error
      }) do
        assert_raises(SystemExit) { Rake::Task["nfl:upload_headshots"].invoke }
      end
    end

    assert_match(/failed 2 of 2 attempted uploads/, err,
                 "the dead source was never OUR failure, so it is not in this denominator " \
                 "— a data gap must not dilute a credential failure")
    assert_match(/1 more had a dead source and are NOT counted here/, err,
                 "say where the third attempt went, or the arithmetic looks like a bug")
    assert_match(/AWS_ACCESS_KEY_ID/, err)
  end

  # A 5xx IS STILL OURS TO REPORT. Excusing every OpenURI::HTTPError would make the
  # lane silent through an ESPN outage, which is a run that genuinely did not do
  # its work. Only "the shelf is empty" is a data gap; "the shop is shut" is not.
  test "a 503 from the source is still a failure that reddens the run" do
    headshot_candidate(45, team_slug: "buffalo-bills")

    _out, err = capture_io do
      Studio::ImageCache.stub(:cache!, ->(**) { raise dead_source_error("503", "Service Unavailable") }) do
        assert_raises(SystemExit) { Rake::Task["nfl:upload_headshots"].invoke }
      end
    end

    assert_match(/failed 1 of 1 attempted uploads/, err)
    assert_match(/503 Service Unavailable/, err,
                 "the cause has to reach stderr, because the [!] line is on stdout and the " \
                 "rebuild lane discards stdout")
  end

  # LOOSE END, MEASURED AND FIXED: the abort used to say "read the [!] lines above",
  # and bin/ecosystem-build runs this task with `>/dev/null`, so it pointed the
  # operator at output the lane had already discarded. The causes now ride in the
  # verdict body itself, on the channel that survives.
  test "the abort carries the per-athlete causes instead of pointing at discarded stdout" do
    headshot_candidate(46, team_slug: "buffalo-bills")
    headshot_candidate(47, team_slug: "buffalo-bills")

    _out, err = capture_io do
      Studio::ImageCache.stub(:cache!, ->(**) { raise Aws::Errors::MissingCredentialsError, "no creds" }) do
        assert_raises(SystemExit) { Rake::Task["nfl:upload_headshots"].invoke }
      end
    end

    assert_match(/Causes: /, err)
    assert_match(/Aws::Errors::MissingCredentialsError/, err,
                 "the exception CLASS is what tells an operator AWS from ESPN in one look")
    refute_match(/read the \[!\] lines above/, err,
                 "the lane discards stdout, so an instruction to read it is an instruction " \
                 "the operator cannot follow")
  end

  # THE CAUSE LIST IS CAPPED. A credential failure across 2,043 athletes would put
  # 2,043 pairs into a rebuild log line otherwise, and a line nobody can read is
  # the same as a line nobody was given.
  test "the cause list is capped at three with a remainder count" do
    5.times { |i| headshot_candidate(50 + i, team_slug: "buffalo-bills") }

    _out, err = capture_io do
      Studio::ImageCache.stub(:cache!, ->(**) { raise Aws::Errors::MissingCredentialsError, "no creds" }) do
        assert_raises(SystemExit) { Rake::Task["nfl:upload_headshots"].invoke }
      end
    end

    assert_match(/\(and 2 more\)/, err)
    assert_equal 3, err.scan(/Aws::Errors::MissingCredentialsError/).size,
                 "three named causes, not five — the remainder is a count"
  end

  # THE WARM STEADY STATE, IN PRODUCTION'S ACTUAL SHAPE, which is the acceptance
  # criterion: 2,043 complete plus 5 whose source 404s. Scaled to 1 + 2. This is
  # the run that was reddening every rebuild.
  test "a warm re-run whose only remaining work has dead sources stays green" do
    complete = headshot_candidate(60, team_slug: "buffalo-bills")
    cache_variants(complete, %w[original 100 400])
    dead = headshot_candidate(61, team_slug: "buffalo-bills")

    out, err = capture_io do
      Studio::ImageCache.stub(:cache!, ->(**) { raise dead_source_error }) do
        refute_aborts { Rake::Task["nfl:upload_headshots"].invoke }
      end
    end

    assert_equal "", err, "this is production's healthy steady state — every headshot that " \
                          "CAN be cached is cached, and a rebuild that reddens on it trains " \
                          "an operator to ignore a red rebuild"
    assert_match(/#{dead.person_slug}/, out, "the residue is named, which is the honest way " \
                                             "to ask for the data to be fixed")
    refute_match(/attempted 0 of/, out + err,
                 "a dead source counts as ATTEMPTED — the request went out and the shelf was " \
                 "empty, so the decline rule must not fire on it either")
  end

  # THE TWO RESIDUES ARE TWO LISTS, because they are two chores: a sourceless
  # athlete needs the COLUMN filled and a dead source needs a PHOTOGRAPH to exist.
  # One merged list would be a list nobody can act on.
  test "a sourceless athlete and a dead source are reported as separate chores" do
    gap = headshot_candidate(62, espn_headshot_url: nil)
    dead = headshot_candidate(63, team_slug: "buffalo-bills")

    out, err = capture_io do
      Studio::ImageCache.stub(:cache!, ->(**) { raise dead_source_error }) do
        refute_aborts { Rake::Task["nfl:upload_headshots"].invoke }
      end
    end

    assert_equal "", err
    assert_match(/no espn_headshot_url:\s+1/, out)
    assert_match(/dead source \(404\/410\):\s+1/, out)
    assert_match(/NO espn_headshot_url --.*\n.*\n.*\n\s+\[-\] #{gap.person_slug}/, out,
                 "the sourceless athlete is under the list naming nfl:players_seed")
    assert_match(/\[x\] #{dead.person_slug} \(espn_id .*\): HTTP 404/, out,
                 "the dead source is under its own list, with the id and status an operator " \
                 "needs to go and look")
  end

  # HEADSHOT_LIMIT BOUNDS EVERY ATHLETE THIS RUN REACHED FOR, dead sources
  # included: it is a politeness budget at a.espncdn.com, and a 404 costs the same
  # request and the same pause as a hit. Leaving them out would let a limit of 2
  # walk the whole retired catalogue.
  test "HEADSHOT_LIMIT counts a dead source against the wave" do
    4.times { |i| headshot_candidate(70 + i, team_slug: "buffalo-bills") }
    ENV["HEADSHOT_LIMIT"] = "2"

    reached = 0
    capture_io do
      Studio::ImageCache.stub(:cache!, ->(**) { reached += 1; raise dead_source_error }) do
        refute_aborts { Rake::Task["nfl:upload_headshots"].invoke }
      end
    end

    assert_equal 2, reached,
                 "a dead source is a request and a pause, so it spends the wave's budget " \
                 "exactly as a successful upload does"
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
        refute_aborts { Rake::Task["nfl:upload_headshots"].invoke }
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
        refute_aborts { Rake::Task["nfl:upload_headshots"].invoke }
        completed = true
      end
    end

    assert completed, "a bounded wave is a complete run, not a partial failure"
    assert_equal 2, attempts, "the limit bounds the ATTEMPTS, which is the cost being bounded"
  end

  # --- nfl:upload_headshots: the work it cannot SEE -------------------------
  #
  # [integration] The verdicts above grade what the run attempted. This grades
  # whether it can even notice the 2,043 athletes it will never attempt again.

  # THE THIRD HOLE, AND THE ONE THAT MADE THE SECOND ONE PERMANENT. "Already done"
  # is decided from VARIANT PRESENCE, so an athlete whose three variants sit under
  # the WRONG folder is complete forever and the centralized taxonomy never reaches
  # them. MEASURED on production 2026-09-26: 2,043 of 2,043 cached athletes filed
  # under `free-agents/`, every one of them skipped as complete on the next run.
  # The task cannot repair that — it fetches and uploads, it does not move — so it
  # must at least SAY so, and name the task that can.
  test "the headshot upload names the re-key task for an athlete filed under a stale key" do
    athlete = headshot_candidate(30, team_slug: "buffalo-bills")
    cache_variants(athlete, %w[original 100 400],
                   prefix: "headshots/nfl/free-agents/#{athlete.person_slug}")

    _out, err = capture_io do
      Studio::ImageCache.stub(:cache!, ->(**) { flunk "a complete athlete must not be re-uploaded" }) do
        refute_aborts { Rake::Task["nfl:upload_headshots"].invoke }
      end
    end

    assert_match(/1 athletes carry headshot rows filed under a stale key/, err)
    assert_match(/rake nfl:rekey_headshots/, err, "name the task that fixes it, not just the symptom")
    refute_match(/attempted 0 of/, err,
                 "a stale folder name is not work this task declined — every variant IS present, " \
                 "so `needed` is 0 and the uploader's own verdicts must stay quiet")
  end

  # THE GREEN TWIN IS ALREADY ABOVE — "a warm re-run with every headshot already
  # cached stays green and says nothing" asserts stderr is EXACTLY empty, and its
  # rows are filed under the correct prefix. That is what keeps this detector from
  # warning on every healthy rebuild. This case pins the other direction: a row set
  # that is INCOMPLETE and misfiled is reported as both, because the two counters
  # answer different questions.
  test "an incomplete misfiled athlete is counted as both misfiled and attempted" do
    athlete = headshot_candidate(31, team_slug: "buffalo-bills")
    cache_variants(athlete, %w[100 400],
                   prefix: "headshots/nfl/free-agents/#{athlete.person_slug}")

    attempts = 0
    out, err = capture_io do
      Studio::ImageCache.stub(:cache!, ->(**) { attempts += 1; {} }) do
        refute_aborts { Rake::Task["nfl:upload_headshots"].invoke }
      end
    end

    assert_equal 1, attempts, "a missing original is still work this task does"
    assert_match(/misfiled \(stale key\):   1/, out)
    assert_match(/rake nfl:rekey_headshots/, err)
  end

  # --- nfl:rekey_headshots -------------------------------------------------
  #
  # [integration] The repair for the rows above, graded on the same three numbers
  # the uploader grades itself on.

  # THE REAL THING, ACROSS THE DB BOUNDARY. A rostered Seahawk filed under
  # `free-agents/` comes out under his own team, and the row — which is what serves
  # the avatar — names an object that exists.
  test "the re-key task moves a misfiled athlete onto their team folder" do
    athlete = headshot_candidate(32, team_slug: "seattle-seahawks")
    stale = "headshots/nfl/free-agents/#{athlete.person_slug}"
    cache_variants(athlete, %w[original 100 400], prefix: stale)
    objects = %w[original 100 400].index_with { |v| "bytes-#{v}" }
                                  .transform_keys { |v| "#{stale}/#{v}.png" }

    with_fake_bucket(objects) do |bucket|
      capture_io { refute_aborts("nfl:rekey_headshots") { Rake::Task["nfl:rekey_headshots"].invoke } }

      keys = athlete.image_caches.reload.map(&:s3_key)
      assert_equal ["headshots/nfl/seattle-seahawks/#{athlete.person_slug}/100.png",
                    "headshots/nfl/seattle-seahawks/#{athlete.person_slug}/400.png",
                    "headshots/nfl/seattle-seahawks/#{athlete.person_slug}/original.png"], keys.sort
      assert keys.all? { |key| bucket.key?(key) },
             "every row names an object that exists — that is the property the whole ordering buys"
      assert_empty bucket.keys.grep(/free-agents/), "and the orphans are gone"
    end
  end

  # GRADED ON THE MAJORITY, exactly as the uploader is: more failures than
  # successes is the mover not working, which from here is what an S3 permission
  # failure looks like.
  test "the re-key refuses a run where every move failed" do
    _out, err = capture_io do
      assert_raises(SystemExit) { rekey(considered: 2, rekeyed: 0, failed: 2) }
    end

    assert_match(/failed 2 of 2 attempted re-keys/, err)
    assert_match(/AWS_ACCESS_KEY_ID/, err, "name the credential an operator goes and checks")
    assert_match(/NO AVATAR WAS LOST/, err,
                 "the ordering guarantees it, so the abort must say it — otherwise the operator's " \
                 "first instinct is to go looking for missing images")
  end

  # THE GREEN TWIN. One unreadable object is an afternoon S3 is having; reddening
  # the repair for it is how an operator learns to stop running it.
  test "the re-key accepts a run where one move of three failed" do
    completed = false
    capture_io { refute_aborts("nfl:rekey_headshots") { rekey(considered: 3, rekeyed: 2, failed: 1) }; completed = true }

    assert completed, "2 successes against 1 failure is one bad object, not a broken mover"
  end

  # NOTHING TO DO IS NOT A FAILURE, and `failed > rekeyed` must not fire on a tie
  # at zero — the state a healthy ecosystem is in permanently once the repair has
  # run.
  test "the re-key accepts a run with nothing to move" do
    completed = false
    _out, err = capture_io { refute_aborts("nfl:rekey_headshots") { rekey }; completed = true }

    assert completed, "a tie at zero is nothing to do"
    assert_equal "", err
  end

  # THE WARM RE-RUN, which is what every run after the repair looks like: thousands
  # of athletes, every key already correct. It must be silent, or the signal is
  # worthless.
  test "a re-key run where every key is already correct says nothing" do
    completed = false
    _out, err = capture_io { refute_aborts("nfl:rekey_headshots") { rekey(considered: 2051, already_filed: 2051) }; completed = true }

    assert completed
    assert_equal "", err, "`needed` subtracts the correctly filed out precisely so this stays quiet"
  end

  # FOUND THE WORK AND DECLINED IT. Structurally unreachable today — there is no
  # `next` between the staleness check and the move — so this grades the VERDICT,
  # which is the half that has to already exist when a skip branch is added later.
  test "the re-key refuses a run that found misfiled rows and moved none of them" do
    _out, err = capture_io do
      assert_raises(SystemExit) { rekey(considered: 2, already_filed: 0) }
    end

    assert_match(/attempted 0 of 2 misfiled athletes/, err)
    assert_match(/declining its job/, err)
  end

  # THE SAFETY CATCH IS REPORTED, NOT FATAL. Keeping an object a row still
  # references is the SAFE outcome; it is still worth an operator's eye, because it
  # means the repoint did not land where the service expected.
  test "held orphans are reported without reddening the re-key" do
    completed = false
    _out, err = capture_io { refute_aborts("nfl:rekey_headshots") { rekey(considered: 1, rekeyed: 1, orphans_held: 3) }; completed = true }

    assert completed, "an object that was KEPT is not a failed repair"
    assert_match(/kept 3 old object\(s\)/, err)
  end

  # AN UNDELETED ORPHAN IS INERT: nothing references it, so it serves nothing and
  # costs storage. Reported, never fatal — the repair itself succeeded.
  test "an undeletable orphan is reported without reddening the re-key" do
    completed = false
    _out, err = capture_io { refute_aborts("nfl:rekey_headshots") { rekey(considered: 1, rekeyed: 1, orphans_failed: 2) }; completed = true }

    assert completed
    assert_match(/2 old object\(s\) could not be deleted/, err)
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
  # The service raising rather than returning a tally — what an unreadable ESPN teams
  # index does, since it raises out of resolve_team_ids! before the per-team loop and
  # therefore before any per-team row could be filed.
  def scrape_raising
    fake = Object.new
    fake.define_singleton_method(:call) do
      raise Espn::ScrapeDepthCharts::SourceUnavailable, "ESPN has no teams index at https://site.web.api.espn.com/apis/site/v2/sports/football/nfl/teams (404)"
    end
    Espn::ScrapeDepthCharts.stub(:new, ->(**) { fake }) do
      Rake::Task["espn:scrape_depth_charts"].invoke
    end
  end

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
  # A rake `abort` raises SystemExit, which is NOT a StandardError — Minitest does
  # not rescue it. A task that wrongly aborts therefore kills the whole suite
  # PROCESS with a bare exit 1, no dots and no failure name, and the
  # `assert completed` line after the invoke never runs at all. MEASURED while
  # mutation-testing this file: restoring the contract precondition made the run
  # print `# Running:` and nothing else. Naming it here turns that into a
  # readable failure attributed to the test that caused it.
  def refute_aborts(task = "nfl:upload_headshots")
    yield
  rescue SystemExit => e
    flunk "#{task} aborted a run it should have completed: #{e.message}"
  end

  # THE REAL EXCEPTION THE LANE SEES, not a stand-in. Studio::ImageCache.cache!
  # fetches through open-uri (`fetch_remote` -> `URI.open`), so a retired ESPN
  # headshot arrives as an OpenURI::HTTPError whose `io.status` is
  # `["404", "Not Found"]`. Built genuinely rather than doubled, because a double
  # carrying only a `message` would pass a classifier that reads the message and
  # would prove nothing about one that reads the status — and the status is the
  # reliable half: `e.message` is whatever the server's reason phrase said.
  def dead_source_error(status = "404", reason = "Not Found")
    io = StringIO.new("")
    io.extend(OpenURI::Meta)
    io.status = [status, reason]
    OpenURI::HTTPError.new("#{status} #{reason}", io)
  end

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

  # `prefix:` defaults to the key the model would write today, which is the shape
  # a healthy row set has. Pass it explicitly to build the PRODUCTION shape after
  # the 2026-09-26 backfill: complete variants filed under the wrong folder.
  def cache_variants(athlete, variants, prefix: athlete.headshot_key_prefix)
    variants.each do |variant|
      ImageCache.create!(owner: athlete, purpose: "headshot", variant: variant,
                         s3_key: "#{prefix}/#{variant}.png",
                         content_type: "image/png")
    end
    athlete.reload
  end

  # THE TALLY-GRADING SEAM, the same one `scrape` above uses: the rake task's job
  # is to READ a tally and decide, and the service's job is to produce one. Stubbed
  # apart so each verdict can be exercised against the exact numbers that trigger
  # it, including numbers no live run can currently produce.
  def rekey(**tally)
    stats = Hash.new(0).merge(tally)
    fake = Object.new
    fake.define_singleton_method(:call) { stats }
    Athletes::RekeyHeadshots.stub(:new, ->(**) { fake }) do
      Rake::Task["nfl:rekey_headshots"].invoke
    end
  end

  # A BUCKET IN A HASH. The service's own unit test owns the ordering assertions;
  # here it exists only so the rake task can be invoked across a real DB boundary
  # without credentials.
  def with_fake_bucket(objects)
    Studio::S3.stub(:exists?, ->(key:) { objects.key?(key) }) do
      Studio::S3.stub(:download, ->(key:) { objects.fetch(key) }) do
        Studio::S3.stub(:upload, ->(key:, body:, **) { objects[key] = body; key }) do
          Studio::S3.stub(:delete, ->(key:) { objects.delete(key); nil }) do
            yield objects
          end
        end
      end
    end
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
