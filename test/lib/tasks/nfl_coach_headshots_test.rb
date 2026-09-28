require "test_helper"
require "rake"
# THE FETCH LIBRARY THE LANE ACTUALLY USES. `nfl:link_coach_headshots` reads ESPN
# through `URI.open`, so ESPN's 403 arrives as an OpenURI::HTTPError rather than
# as a response object with a status to inspect. Required here so the cases below
# raise the genuine class the task must survive, not a stand-in.
require "open-uri"
require "stringio"

# [unit][integration] `nfl:link_coach_headshots` -- the host it dials, the name it
# gives, and what it does when ESPN hands it nothing.
#
# ── WHY THIS FILE EXISTS ──────────────────────────────────────────────────────
#
# The lane read `site.api.espn.com`, which serves the identical document to curl
# and 403s Ruby from behind an Akamai deny page. MEASURED 2026-09-27 THROUGH
# `URI.open` ITSELF -- the call this task makes -- with the working host as a
# control, so the failure is pinned on the host rather than on how Ruby asks:
#
#     URI.open("https://<host>/apis/site/v2/sports/football/nfl/teams")
#
#     HOST                   UA CONDITION           STATUS         BYTES
#     site.api.espn.com      open-uri default       403 Forbidden     437
#     site.api.espn.com      Espn::Api::USER_AGENT  403 Forbidden     437
#     site.web.api.espn.com  open-uri default       200           148,848   <- control
#     site.web.api.espn.com  Espn::Api::USER_AGENT  200           148,848   <- control
#
# THE CONTROL IS THE POINT. Two cells of the same call, in the same process,
# differing only in the host: the dead one cannot be revived by dressing Ruby up,
# and the live one needs no costume. A `curl` returning 200 proves nothing here,
# which is exactly how this host survived in three places at once.
#
# ── AND WHY IT ASSERTS A LOUD FAILURE ────────────────────────────────────────
#
# The 403 was not the whole defect. `teams_resp.dig(...)` returning an empty
# array walked the loop zero times, printed a tidy column of zeros, and exited 0
# -- so the dead host could also present as a clean run that did nothing. A lane
# that cannot fail cannot be trusted when it passes.
#
# ── AND WHY IT CAME BACK ONE LOOP LOWER (`coach-link-lane-false-green`) ───────
#
# The abort above guards the INDEX fetch. Past it, every per-team read sat under
# a bare `rescue => e; failed += 1`, and the task then ended on `puts`: nothing
# read `failed`, so a run where no team produced a coach exited 0. MEASURED in
# this desk before the fix, with a two-team index and open-uri raising
# `OpenURI::HTTPError 500` for every per-team read:
#
#     matched/updated:      0
#     skipped (no team):    1
#     failed:               1
#     EXIT CODE: 0
#
# (One team matched a fixture abbrev and raised; the other had no fixture Team,
# so the same no-op arrived through two different counters. That is why the rule
# this file now asserts grades what ended up ON FILE and not the failure count:
# "every team failed" is one way to link no coach, and it is not the only one.)
#
# THE REACHABILITY WAS FIRST JUDGED WRONG, and the correction is the point. This
# lane was parked once as "a misleading report line, not a false green" because
# `nfl:link_coach_headshots` does not appear in bin/ecosystem-build. It IS reached,
# through three hops that never spell its name, re-verified in this desk:
#
#   1. bin/ecosystem-build's app phase runs `rails db:create db:migrate db:seed`
#      with BOTH streams sent to /dev/null and only the exit status read, and it
#      `exit 1`s the whole rebuild when that status is non-zero.
#   2. db/seeds.rb loads every db/seeds/*.rb in sorted order -- MEASURED: 37 files,
#      with 32_headshot_links.rb at sort index 23.
#   3. db/seeds/32_headshot_links.rb invokes `nfl:link_coach_headshots` and
#      `nfl:link_coach_headshots_from_team_sites` through `Rake::Task#invoke`.
#
# A GREP MISS PROVES THE STRING IS ABSENT, NOT THAT THE CODE IS UNREACHED. And
# because that lane discards both streams, the exit status is the ONLY signal the
# rebuild can read: every `puts` in this task is invisible there, which is why the
# verdict had to become an exit code rather than a louder report line.
class NflCoachHeadshotsTest < ActiveSupport::TestCase
  TASK = "nfl:link_coach_headshots".freeze

  # THE THREE SPELLINGS THE RAKE LANE MAY NOT CARRY, named through Espn::Api so
  # this list cannot drift from the module the production code reads.
  ESPN_API_HOSTS = [Espn::Api::WEB_HOST, Espn::Api::CORE_HOST, Espn::Api::FILTERED_HOST].freeze

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?(TASK)
    Rake::Task[TASK].reenable
  end

  # --- [unit] the host and the name ---------------------------------------

  # THE REGRESSION. One assertion per host so a failure names which half moved.
  test "the teams index URL names Espn::Api::WEB_HOST and never site.api.espn.com" do
    url = teams_index_url

    assert_includes url, Espn::Api::WEB_HOST,
                    "the teams index must be read from the host that serves Ruby"
    refute_includes url, Espn::Api::FILTERED_HOST,
                    "site.api.espn.com answers curl with 200 and Ruby with 403 -- " \
                    "measured through URI.open, with site.web.api as a 200 control. " \
                    "It must never be dialled from this lane."
  end

  # THE OTHER HOST IN THE SAME LANE. sports.core.api.espn.com never filtered, so
  # this is not a repair -- it is refusing to leave a second spelling of a host
  # in a file whose first spelling just cost a day.
  test "the per-team coaches URL names Espn::Api::CORE_HOST" do
    url = ESPN_TEAM_COACHES_URL.call("2")

    assert_includes url, Espn::Api::CORE_HOST
    refute_includes url, Espn::Api::FILTERED_HOST
  end

  # THE ASSERTION ABOVE CHECKS A VALUE, WHICH IS NOT THE WHOLE ACCEPTANCE. A
  # hardcoded "site.web.api.espn.com" would satisfy every case above while
  # re-creating the exact condition that killed this lane: a host spelled in two
  # files, one of which somebody later edits. MEASURED by mutation -- replacing
  # `Espn::Api::CORE_HOST` with its literal left the whole file green -- so the
  # rule "the host comes from Espn::Api" needs a case that can see a literal.
  #
  # Comment lines are exempt on purpose: the measurement table in nfl.rake has to
  # be able to NAME the dead host, and a rule that forbade that would be a rule
  # against writing down what was measured.
  #
  # IT READS EVERY RAKE FILE, NOT JUST THE ONE THAT ROTTED. Reading only nfl.rake
  # made the guard a note about one file rather than a rule about the rake lane:
  # lib/tasks/espn.rake grades the depth-chart scrape and any future lane may dial
  # ESPN, and the defect this guard exists for was ONE HOST IN TWO PLACES. A guard
  # that can only see the place it already knows about cannot catch the third copy,
  # which is how this host survived in three at once.
  test "no rake file in lib/tasks spells an ESPN host literally -- they come from Espn::Api" do
    files = rake_files
    refute_empty files, "the guard read no files at all, so it can refuse nothing"
    assert_equal Dir[Rails.root.join("lib/tasks/*.rake")].sort, files,
                 "the guard must read the whole rake directory; a hand-kept list is how " \
                 "the third copy of this host stayed invisible"

    files.each do |path|
      ESPN_API_HOSTS.each do |host|
        refute espn_host_literal?(File.read(path), host),
               "#{host} is spelled out in #{path.sub("#{Rails.root}/", '')}. Reference the " \
               "Espn::Api constant instead -- two copies of a host is the defect " \
               "this lane was fixed for, not a style preference."
      end
    end
  end

  # THE DETECTOR, ASKED OF ITS OWN MOTIVATING CASES. The loop above walks 30-odd
  # files and cannot plant a literal in each, so what "bites on every member" means
  # here is that the PREDICATE bites -- proved against synthetic source rather than
  # inferred from a green sweep of a directory that is currently clean. A clean
  # sweep is evidence about the directory, never about the detector.
  #
  # THE CONTINUATION CASE IS WHY THIS IS FLATTEN-THEN-SUBSTRING AND NOT A LINE
  # MATCH. Ruby concatenates adjacent string literals, so a host split across a
  # `" \` seam -- the idiom nfl.rake already uses on nearly every abort message --
  # is one host at run time and two fragments to a line-by-line reader. MEASURED
  # below: the naive `readlines.grep_v(/^\s*#/).join` this guard used to do is
  # BLIND to that spelling, and it is the spelling a tidy-up would produce.
  test "the ESPN host detector catches a literal however it is spelled" do
    ESPN_API_HOSTS.each do |host|
      assert espn_host_literal?(%(HOST = "#{host}".freeze\n), host),
             "a plain literal must be caught"
      assert espn_host_literal?(%(URL = "https://#{host}/apis"\n), host),
             "a literal inside a URL must be caught"

      # The seam a line reader cannot see: two fragments Ruby joins into one host.
      head, tail = host[0, 5], host[5..]
      wrapped = %(URL = "https://#{head}" \\\n      "#{tail}/apis"\n)
      assert espn_host_literal?(wrapped, host),
             "a host split across a string-continuation seam is still that host at run time"
      refute_includes wrapped.lines.grep_v(/^\s*#/).join, host,
                      "this case only proves something if a line-joining reader MISSES it"
    end
  end

  # THE EXEMPTION, ASKED OF ITS OWN CONDITION rather than asserted. nfl.rake's
  # measurement table has to be able to name the dead host, so full-line comments
  # are stripped before the search -- and a guard that could not tell a comment
  # from code would either forbid writing down what was measured or catch nothing.
  test "the ESPN host detector ignores a host named in a comment" do
    assert espn_host_literal?(%(  HOST = "#{Espn::Api::FILTERED_HOST}"\n), Espn::Api::FILTERED_HOST)
    refute espn_host_literal?(%(  #     #{Espn::Api::FILTERED_HOST}   403 Forbidden\n),
                              Espn::Api::FILTERED_HOST),
           "the measurement table in nfl.rake must stay legal"
  end

  # LAZY BY NECESSITY, NOT BY TASTE, and asserted so nobody "tidies" it back into
  # a String. MEASURED 2026-09-27 with a throwaway .rake file and `rake -T`:
  # Rails loads lib/tasks/*.rake BEFORE the `:environment` task sets Zeitwerk up,
  # so a String constant interpolating `Espn::Api::WEB_HOST` raises
  # `NameError: uninitialized constant Espn` and takes EVERY rake invocation in
  # the repository down with it -- not just this task's.
  test "the teams index URL is resolved lazily so rake can load this file without Rails" do
    assert_respond_to ESPN_TEAMS_INDEX_URL, :call,
                      "a String here interpolates Espn::Api at rake-LOAD time, where " \
                      "Zeitwerk is not up yet; measured, that NameError breaks every rake task"
  end

  # WHO WE SAY WE ARE, ON EVERY REQUEST THE LANE MAKES. open-uri does not send a
  # bare request when the header is unset: measured off a local socket
  # 2026-09-27, it fills in `User-Agent: Ruby`. So "we set no UA" was never an
  # option -- the only choice was between Ruby's name and our own.
  test "every ESPN read carries the Espn::Api user agent" do
    calls = refute_aborts { run_task(index: index_doc, coaches: coaches_doc, coach: coach_doc) }

    assert_equal 3, calls.size, "the lane reads the index, the team's coaches, and the coach"
    calls.each do |call|
      assert_equal Espn::Api::USER_AGENT, call[:options]["User-Agent"],
                   "#{call[:url]} was fetched as `User-Agent: Ruby`"
    end
  end

  # HOW LONG THE REBUILD MAY WAIT ON ONE SOCKET, and the reason this is asserted
  # rather than left to the library. Left unset, open-uri does not wait for ever:
  # MEASURED in this desk on Ruby 3.3.11, `Net::HTTP.new(...)` reports
  # `open_timeout=60 read_timeout=60`. That is the number this lane inherits, and
  # it is the wrong one HERE -- the task makes 1 index read plus 2 reads per team,
  # so 32 teams is 65 reads and a stalled ESPN could hold `db:seed` for 65 minutes
  # on read alone before this task's own guards ever get to speak. The sibling
  # scrape in the same file already chose 15s per read; this is the same budget
  # for the same reason, and it caps the same 65 reads at about 16 minutes.
  #
  # ASSERTED ON EVERY CALL, NOT ON THE CONSTANT. The index read and the two
  # per-team reads go through one lambda today, and a future second fetch site
  # that forgot the budget is exactly what this case is for.
  test "every ESPN read carries a read timeout" do
    calls = refute_aborts { run_task(index: index_doc, coaches: coaches_doc, coach: coach_doc) }

    assert_equal 3, calls.size
    calls.each do |call|
      timeout = call[:options]["read_timeout"]
      assert timeout, "#{call[:url]} was read with open-uri's inherited 60s default; a rebuild " \
                      "lane must name its own budget"
      assert_operator timeout, :<=, 30, "#{call[:url]} waits longer than the sibling scrape does"
    end
  end

  # --- [integration] the lane's verdict -----------------------------------

  # THE SECOND HALF OF THE DEFECT. An index that resolves no teams is not a
  # successful run with nothing to do: this task's ONLY source of work is that
  # list, so zero teams means zero coaches were considered and the run is a
  # no-op wearing a clean exit code.
  test "a run resolving no ESPN teams fails loudly" do
    out, err = capture_io do
      assert_raises(SystemExit) { run_task(index: empty_index_doc) }
    end

    assert_match(/0 ESPN teams|resolved 0/i, err,
                 "the abort must say the team list was empty, not just that something went wrong")
    assert_match(/#{Regexp.escape(Espn::Api::WEB_HOST)}/, err + out,
                 "name the host that was asked, so the next operator can re-ask it by hand")
  end

  # THE OTHER WAY TO RESOLVE NO TEAMS, and a case this file was missing until a
  # mutation found the hole. MEASURED: with `Array()` removed from the dig, the
  # whole file stayed green -- so the guard's nil arm was untested. Asked of the
  # expression directly, the two inputs are not interchangeable:
  #
  #     dig -> nil   WITH Array() -> []      WITHOUT -> NoMethodError
  #     dig -> []    WITH Array() -> []      WITHOUT -> []
  #
  # An empty list and a MOVED document are different facts about ESPN, and only
  # the first one was covered. Both must reach the same legible abort, because a
  # NoMethodError backtrace out of a rake task tells an operator nothing about
  # which host was asked or what it said.
  test "a run whose index shape moved fails as loudly as an empty one" do
    out, err = capture_io do
      assert_raises(SystemExit) { run_task(index: moved_index_doc) }
    end

    assert_match(/resolved 0/i, err)
    assert_match(/sports\[0\]\.leagues\[0\]\.teams/, err,
                 "name the path that was dug, so the operator can diff it against the document")
    assert_match(/#{Regexp.escape(Espn::Api::WEB_HOST)}/, err + out)
  end

  # THE GREEN TWIN, differing by exactly one team. A guard that refused every run
  # would pass the case above; this is what catches it.
  test "a run resolving one ESPN team completes" do
    completed = false
    capture_io do
      refute_aborts { run_task(index: index_doc, coaches: coaches_doc, coach: coach_doc) }
      completed = true
    end

    assert completed, "one resolved team is a working run -- a guard that aborts it is a " \
                      "guard operators learn to route around"
    assert_equal "1234", Coach.find_by(team_slug: "buffalo-bills", role: "head_coach").espn_id
  end

  # THE FAILURE MODE THAT STARTED THIS, asserted as a legible abort rather than
  # an open-uri backtrace. If the host is ever moved back, the operator must be
  # told which host answered what -- because their `curl` will say 200.
  test "a 403 on the index aborts naming the host trap" do
    out, err = capture_io do
      assert_raises(SystemExit) { run_task(index_error: http_error("403", "Forbidden")) }
    end

    assert_match(/403/, err, "carry the status ESPN actually answered")
    assert_match(/curl/i, err + out,
                 "the abort must warn that hand-verifying with curl will succeed while " \
                 "this task fails -- that asymmetry IS the bug")
  end

  # --- [integration] the per-team verdict ---------------------------------

  # THE REGRESSION THIS TASK WAS FILED FOR, and the lowest tier that can see it:
  # the index guard is satisfied -- ESPN answered, two teams resolved -- and then
  # every per-team read raises into the loop's `rescue => e; failed += 1`. Before
  # the fix the task ended on `puts` and the process exited 0 with `failed: 2`,
  # inside a `db:seed` whose only signal to bin/ecosystem-build is that status.
  test "a run whose every team failed exits non-zero" do
    out, err = capture_io do
      assert_raises(SystemExit) do
        run_task(responses: [two_team_index_doc, http_error("500", "Internal Server Error")])
      end
    end

    assert_match(/0 of 2/, err, "say how much of the work landed, not just that it went wrong")
    assert_match(/500/, err + out, "carry the status ESPN answered, so the cause is readable " \
                                   "where the rebuild lane throws stdout away")
  end

  # THE OTHER WAY TO LINK NO COACH, and the reason this lane is graded on what
  # ended up ON FILE rather than on `failed`. MEASURED in this desk before the fix,
  # with both fixture NFL teams in the index and every per-team read raising: the
  # run reported `failed: 1` AND `skipped (no team): 1`, so a rule reading only
  # `failed == teams` would have called that no-op a partial failure and stayed
  # green. Here nothing raises at all -- ESPN simply names two teams we do not
  # have -- and not one coach was linked.
  test "a run that links no coach exits non-zero even when nothing raised" do
    out, err = capture_io do
      assert_raises(SystemExit) { run_task(responses: [unknown_team_index_doc]) }
    end

    assert_match(/0 of 2/, err)
    assert_match(/no team match/i, err + out,
                 "name the residue that swallowed the work, so the operator knows which " \
                 "table to look at")
  end

  # THE GREEN TWIN, DIFFERING BY EXACTLY ONE TEAM THAT WORKED. A rule that fired
  # on any failure would pass both cases above and redden a normal ESPN afternoon,
  # which is the same defect in the other costume: one dead team must cost the
  # other 31 nothing but a sentence on stderr.
  test "a run where one of two teams failed completes with a warning" do
    completed = false
    out, err = capture_io do
      refute_aborts do
        run_task(responses: [two_team_index_doc, coaches_doc, coach_doc,
                             http_error("500", "Internal Server Error")])
      end
      completed = true
    end

    assert completed, "a partial run is a working lane; a guard that aborts it is a guard " \
                      "operators learn to route around"
    assert_match(/1 of 2/, err + out, "the partial must still be legible on stderr, which is " \
                                      "the only channel the rebuild lane keeps")
    assert_equal "1234", Coach.find_by(team_slug: "buffalo-bills", role: "head_coach").espn_id
  end

  # THE WARM RE-RUN, WHICH MUST BE SILENT. `skipped (unchanged)` is the steady
  # state of a seeded machine -- ESPN says what we already have -- and it counts as
  # work on file, not as work declined. A verdict that fired here would fire on
  # every rebuild after the first, and a verdict that fires on a healthy run is a
  # verdict nobody reads.
  test "a run where every team was already on file is silent and green" do
    Coach.find_by(team_slug: "buffalo-bills", role: "head_coach")
         .update!(espn_id: "1234", espn_headshot_url: coach_doc.dig("headshot", "href"))

    completed = false
    _out, err = capture_io do
      refute_aborts { run_task(index: index_doc, coaches: coaches_doc, coach: coach_doc) }
      completed = true
    end

    assert completed
    refute_match(/of 1/, err, "an unchanged team is on file, not missed")
  end

  private

  # A BITE ON A GREEN TWIN MUST BE LEGIBLE, and without this it is not. `abort`
  # raises SystemExit, which is not a StandardError, so an unexpected one escapes
  # Minitest and KILLS THE RUNNER: measured while mutating `applied` to drop
  # `skipped_unchanged`, the suite printed no summary line at all and `bin/rails
  # test` merely exited 1. A guard that fires where it should not has to name
  # itself. The idiom is lifted from test/lib/tasks/rebuild_lane_verdict_test.rb.
  def refute_aborts(task = TASK)
    yield
  rescue SystemExit => e
    flunk "#{task} aborted a run it should have completed: #{e.message}"
  end

  # Resolve whichever shape the constant has, so the red this test was written to
  # produce is about the HOST and not about a String failing to answer #call. The
  # shape has its own case above.
  def teams_index_url
    ESPN_TEAMS_INDEX_URL.respond_to?(:call) ? ESPN_TEAMS_INDEX_URL.call : ESPN_TEAMS_INDEX_URL
  end

  # THE REAL EXCEPTION open-uri RAISES, built genuinely rather than doubled: a
  # double carrying only a message would pass a rescue that reads the class and
  # prove nothing about one that reads `io.status`.
  def http_error(status, reason)
    io = StringIO.new("<html>Access Denied</html>")
    io.extend(OpenURI::Meta)
    io.status = [status, reason]
    OpenURI::HTTPError.new("#{status} #{reason}", io)
  end

  # Invoke the task with ESPN replaced at the `URI.open` seam -- the same seam the
  # task uses -- and hand back every call it made so its options can be read off it.
  #
  # `*rest, **kw` because `URI.open(url, read_timeout: 15, "User-Agent" => x)` is
  # ONE mixed hash and lands positionally on open-uri's `def URI.open(name, *rest)`
  # rather than as keywords -- headers and options travel together there, which is
  # why the capture is a single `:options` hash and not a `:headers` one.
  #
  # `responses:` IS A SCRIPT. An entry that is an Exception is RAISED at that
  # position, which is how a per-team failure is expressed, and the LAST entry
  # repeats once the script runs out -- deliberately, so "every team fails" is one
  # error rather than two per team. The narrower `index:`/`coaches:`/`coach:` form
  # builds the same three-entry script.
  def run_task(index: nil, coaches: nil, coach: nil, index_error: nil, responses: nil)
    # DISPATCH BY CALL ORDER, NOT BY URL SUBSTRING. The lane reads exactly three
    # documents per team in a fixed sequence, and the third one is a `$ref` ESPN
    # hands back whose path also contains "/coaches" -- a substring match sent the
    # coach fetch to the coaches document and silently produced a blank espn_id.
    script = responses || [index_error || index, coaches, coach]
    calls = []
    fake = lambda do |url, *rest, **kw|
      options = (rest.last.is_a?(Hash) ? rest.last : {}).merge(kw)
      calls << { url: url.to_s, options: options.transform_keys(&:to_s) }
      step = script.fetch(calls.size - 1, script.last)
      raise step if step.is_a?(Exception)

      StringIO.new(JSON.generate(step))
    end

    URI.stub(:open, fake) { Rake::Task[TASK].invoke }
    calls
  end

  def rake_files
    Dir[Rails.root.join("lib/tasks/*.rake")].sort
  end

  # FLATTEN, THEN SUBSTRING -- never a per-line regex. Three steps, each answering
  # a way the same host can hide from a line reader:
  #
  #   1. drop full-line comments, so nfl.rake's measurement table may name the dead
  #      host (the one exemption, and it has its own case above);
  #   2. join `\`-newline continuations, so a statement that wraps is one string;
  #   3. close `"a" "b"` seams, because Ruby concatenates adjacent literals and a
  #      host split across one IS that host at run time.
  #
  # Step 3 also eats a bare `""`, which is harmless: the only thing asked of the
  # result afterwards is whether it contains a host.
  def espn_host_literal?(source, host)
    source.lines.grep_v(/^\s*#/).join
          .gsub(/\\\n\s*/, "")
          .gsub(/"[ \t]*"/, "")
          .include?(host)
  end

  def index_doc
    { "sports" => [{ "leagues" => [{ "teams" => [
      { "team" => { "id" => "2", "abbreviation" => "BUF" } }
    ] }] }] }
  end

  # TWO TEAMS, BOTH OF WHICH WE HAVE. Two rather than one so a partial run is
  # expressible at all: with one team, "some failed" and "all failed" are the same
  # input and the majority rule could not be told from a fire-on-any-failure rule.
  def two_team_index_doc
    { "sports" => [{ "leagues" => [{ "teams" => [
      { "team" => { "id" => "2",  "abbreviation" => "BUF" } },
      { "team" => { "id" => "15", "abbreviation" => "MIA" } }
    ] }] }] }
  end

  # ESPN ANSWERS, NOTHING RAISES, AND NOT ONE COACH IS LINKED: both abbrevs are
  # real NFL teams we have no Team row for. The lane's own no-op, arriving through
  # `skipped (no team)` instead of through `failed`.
  def unknown_team_index_doc
    { "sports" => [{ "leagues" => [{ "teams" => [
      { "team" => { "id" => "7",  "abbreviation" => "DEN" } },
      { "team" => { "id" => "12", "abbreviation" => "KC"  } }
    ] }] }] }
  end

  # ESPN's shape when it answers but has no teams: the document parses, every
  # `dig` key is present, and the list is empty. This is the run that used to
  # exit 0.
  def empty_index_doc
    { "sports" => [{ "leagues" => [{ "teams" => [] }] }] }
  end

  # ESPN ANSWERED, BUT NOT WITH THIS DOCUMENT: every key past "sports" is gone, so
  # `dig` returns nil rather than an empty list. This is the shape a v3 endpoint or
  # a re-pointed URL produces, and it used to be a NoMethodError.
  def moved_index_doc
    { "sports" => [] }
  end

  def coaches_doc
    { "items" => [{ "$ref" => "https://#{Espn::Api::CORE_HOST}/v2/sports/football/leagues/nfl/coaches/1234" }] }
  end

  def coach_doc
    { "id" => "1234", "firstName" => "Sean", "lastName" => "McDermott",
      "headshot" => { "href" => "https://a.espncdn.com/i/headshots/nfl/coaches/full/1234.png" } }
  end
end
