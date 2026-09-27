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
class NflCoachHeadshotsTest < ActiveSupport::TestCase
  TASK = "nfl:link_coach_headshots".freeze

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
    calls = run_task(index: index_doc, coaches: coaches_doc, coach: coach_doc)

    assert_equal 3, calls.size, "the lane reads the index, the team's coaches, and the coach"
    calls.each do |call|
      assert_equal Espn::Api::USER_AGENT, call[:headers]["User-Agent"],
                   "#{call[:url]} was fetched as `User-Agent: Ruby`"
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

  # THE GREEN TWIN, differing by exactly one team. A guard that refused every run
  # would pass the case above; this is what catches it.
  test "a run resolving one ESPN team completes" do
    completed = false
    capture_io do
      run_task(index: index_doc, coaches: coaches_doc, coach: coach_doc)
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

  private

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
  # task uses -- and hand back every call it made so the UA can be read off it.
  # `*rest, **kw` because `URI.open(url, "User-Agent" => x)` lands the header hash
  # positionally on open-uri's `def URI.open(name, *rest)`, not as keywords.
  def run_task(index: nil, coaches: nil, coach: nil, index_error: nil)
    calls = []
    fake = lambda do |url, *rest, **kw|
      headers = (rest.last.is_a?(Hash) ? rest.last : {}).merge(kw)
      calls << { url: url.to_s, headers: headers.transform_keys(&:to_s) }
      raise index_error if index_error && calls.size == 1

      # DISPATCH BY CALL ORDER, NOT BY URL SUBSTRING. The lane reads exactly three
      # documents in a fixed sequence, and the third one is a `$ref` ESPN hands
      # back whose path also contains "/coaches" -- a substring match sent the
      # coach fetch to the coaches document and silently produced a blank espn_id.
      body = [index, coaches, coach][calls.size - 1]
      StringIO.new(JSON.generate(body))
    end

    URI.stub(:open, fake) { Rake::Task[TASK].invoke }
    calls
  end

  def index_doc
    { "sports" => [{ "leagues" => [{ "teams" => [
      { "team" => { "id" => "2", "abbreviation" => "BUF" } }
    ] }] }] }
  end

  # ESPN's shape when it answers but has no teams: the document parses, every
  # `dig` key is present, and the list is empty. This is the run that used to
  # exit 0.
  def empty_index_doc
    { "sports" => [{ "leagues" => [{ "teams" => [] }] }] }
  end

  def coaches_doc
    { "items" => [{ "$ref" => "https://#{Espn::Api::CORE_HOST}/v2/sports/football/leagues/nfl/coaches/1234" }] }
  end

  def coach_doc
    { "id" => "1234", "firstName" => "Sean", "lastName" => "McDermott",
      "headshot" => { "href" => "https://a.espncdn.com/i/headshots/nfl/coaches/full/1234.png" } }
  end
end
