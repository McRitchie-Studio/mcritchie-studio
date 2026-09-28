require "test_helper"
require "rake"
# THE FETCH LIBRARY THE LANE ACTUALLY USES. `nfl:link_coach_headshots_from_team_sites`
# reads NFL.com through `URI.open`, so a missing coaches page arrives as an
# OpenURI::HTTPError and not as a response object with a status to inspect.
# Required here so the cases below raise the genuine class the task rescues.
require "open-uri"
require "stringio"

# [integration] `nfl:link_coach_headshots_from_team_sites` -- whether the lane can
# report that it linked nothing.
#
# ── WHY THIS FILE EXISTS ──────────────────────────────────────────────────────
#
# It is the SECOND task db/seeds/32_headshot_links.rb invokes, one line below
# `nfl:link_coach_headshots`, and it carried the same defect: `failed_team` was
# counted, printed, and read by nothing, so the task ended by returning and the
# process exited 0 however many teams it lost. This lane is the only source of a
# coordinator's headshot URL at all -- ESPN's coach API has no `headshot.href` for
# any of them -- so a silent total failure costs three of the four coaches on every
# team their avatar.
#
# MEASURED IN A DESK BEFORE THE FIX, two fixture teams carrying a coaches_url and
# every candidate URL answering 404:
#
#     failed (team page):   2
#     EXIT CODE: 0
#
# ── AND WHY THE VERDICT READS WHAT LANDED, NOT WHAT FAILED ───────────────────
#
# `failed_team` counts teams whose PAGE could not be read. It cannot see the other
# way to link nothing: 32 pages that load and yield no coach, which is what a
# change to NFL.com's markup looks like from here. Both are the lane not happening,
# so both are graded, and the grade is the number of Coach rows whose headshot URL
# this lane put or confirmed on file.
#
# THE PARTIAL STAYS GREEN ON PURPOSE. Two teams' pages down is a normal NFL.com
# afternoon, and a lane that reddens a rebuild over it is a lane an operator learns
# to route around -- the same defect in another costume.
class NflCoachTeamSitesTest < ActiveSupport::TestCase
  TASK = "nfl:link_coach_headshots_from_team_sites".freeze

  BILLS_URL    = "https://www.buffalobills.com/team/coaches/".freeze
  BILLS_ALT    = "https://www.buffalobills.com/team/coaches-roster/".freeze
  DOLPHINS_URL = "https://www.miamidolphins.com/team/coaches/".freeze

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?(TASK)
    Rake::Task[TASK].reenable
    # THE FIXTURES CARRY NO coaches_url, so the population is set here per case.
    # That is deliberate: "no NFL team has a coaches page on file" is itself one of
    # the runs this file grades, and it has to be reachable.
    Team.where(league: "nfl").update_all(coaches_url: nil)
  end

  # --- the lane's verdict --------------------------------------------------

  # THE REGRESSION. Both teams carry a page, neither page can be read, not one
  # coach is linked -- and before this guard the task printed `failed (team page):
  # 2` and returned, so `db:seed` exited 0 and bin/ecosystem-build logged a seeded
  # database.
  test "a run whose every team page was unreachable exits non-zero" do
    give_coaches_urls(bills: BILLS_URL, dolphins: DOLPHINS_URL)

    out, err = capture_io do
      assert_raises(SystemExit) { run_task(pages: {}) }
    end

    assert_match(/linked 0 coaches across 2 NFL teams/, err,
                 "say how much of the work landed, not just that it went wrong")
    assert_match(/coaches page/i, err + out,
                 "name what could not be read, so the operator knows whether to look at " \
                 "NFL.com or at our own URLs")
  end

  # THE OTHER WAY TO LINK NOTHING, and the one `failed_team` is structurally blind
  # to: every page loads, and none of them yields a coach card this lane can match.
  # That is what a markup change at NFL.com looks like from inside the task, and it
  # is the shape that would otherwise survive the guard above.
  test "a run whose pages all loaded but matched no coach exits non-zero" do
    give_coaches_urls(bills: BILLS_URL, dolphins: DOLPHINS_URL)

    _out, err = capture_io do
      assert_raises(SystemExit) do
        run_task(pages: { BILLS_URL => "<html><body>no coaches here</body></html>",
                          DOLPHINS_URL => "<html><body>no coaches here</body></html>" })
      end
    end

    assert_match(/linked 0 coaches across 2 NFL teams/, err)
    assert_match(/2 of their pages WERE read/, err,
                 "a page that loads and yields nothing is a different chore from a page " \
                 "that will not load, and the verdict has to say which happened")
    assert_match(/markup/i, err, "name the thing that moved, not just that nothing matched")
  end

  # A RUN WITH NO SOURCE OF WORK IS NOT A RUN WITH NOTHING TO DO. `Team.coaches_url`
  # is written by db/seeds/10_teams_nfl.rb, which sorts BEFORE the seed that invokes
  # this task, so an empty population means the teams were never seeded -- and the
  # loop then walked zero times, printed a column of zeros and exited 0.
  test "a run where no NFL team carries a coaches page exits non-zero" do
    _out, err = capture_io do
      assert_raises(SystemExit) { run_task(pages: {}) }
    end

    assert_match(/no NFL team/i, err)
    assert_match(/coaches_url/, err, "name the column, so the operator can check it")
  end

  # THE GREEN TWIN, DIFFERING BY EXACTLY ONE TEAM THAT WORKED. A guard that refused
  # any lost team would pass every case above and redden a normal afternoon.
  test "a run where one of two team pages failed completes with a warning" do
    give_coaches_urls(bills: BILLS_URL, dolphins: DOLPHINS_URL)

    completed = false
    out, err = capture_io do
      refute_aborts { run_task(pages: { BILLS_URL => bills_coaches_page }) }
      completed = true
    end

    assert completed, "one unreachable team is a bad afternoon, not a scrape that never " \
                      "happened -- a guard that refuses it is a guard operators switch off"
    assert_match(/1 of 2/, err + out, "the partial must be legible on stderr, which is the " \
                                      "only channel the rebuild lane keeps")
    assert_match(%r{/image/upload/t_headshot_desktop_3x/f_auto/},
                 Coach.find_by(team_slug: "buffalo-bills", role: "head_coach").espn_headshot_url,
                 "the working half of the run must still do its job")
  end

  # THE WARM RE-RUN, WHICH MUST BE SILENT. NFL.com serving the same photo we
  # already hold is this lane's steady state on a seeded machine, and a verdict
  # that fired there would fire on every rebuild after the first.
  test "a run where every coach was already on file is silent and green" do
    give_coaches_urls(bills: BILLS_URL)
    capture_io { refute_aborts { run_task(pages: { BILLS_URL => bills_coaches_page }) } }
    Rake::Task[TASK].reenable

    completed = false
    _out, err = capture_io do
      refute_aborts { run_task(pages: { BILLS_URL => bills_coaches_page }) }
      completed = true
    end

    assert completed
    assert_equal "", err, "an unchanged coach is on file, not lost"
  end

  # HOW LONG THE REBUILD MAY WAIT ON ONE SOCKET, asserted on every fetch rather
  # than read off the source. This lane tries up to two URLs per team, so 32 teams
  # is up to 64 reads; measured on Ruby 3.3.11 an unset budget is Net::HTTP's
  # inherited 60s, which is over an hour of a `db:seed` that prints nothing.
  test "every NFL.com read carries a read timeout" do
    give_coaches_urls(bills: BILLS_URL)

    calls = nil
    capture_io { calls = refute_aborts { run_task(pages: { BILLS_URL => bills_coaches_page }) } }

    refute_empty calls
    calls.each do |call|
      timeout = call[:options]["read_timeout"]
      assert timeout, "#{call[:url]} was read with open-uri's inherited 60s default"
      assert_operator timeout, :<=, 30
    end
  end

  # THE ALTERNATE PATH IS STILL TRIED, and it is asserted here because the verdict
  # above counts a team as lost only after BOTH candidates fail. Two clubs serve
  # /team/coaches-roster/ instead of /team/coaches/, so a guard that graded the
  # first URL alone would call them failures for ever.
  test "a team whose page lives at the alternate path is not counted as lost" do
    give_coaches_urls(bills: BILLS_URL)

    completed = false
    _out, err = capture_io do
      refute_aborts { run_task(pages: { BILLS_ALT => bills_coaches_page }) }
      completed = true
    end

    assert completed
    assert_equal "", err, "the second candidate URL answered, so nothing was lost"
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

  def give_coaches_urls(bills: nil, dolphins: nil)
    Team.find_by!(slug: "buffalo-bills").update!(coaches_url: bills) if bills
    Team.find_by!(slug: "miami-dolphins").update!(coaches_url: dolphins) if dolphins
  end

  # Invoke the task with NFL.com replaced at the `URI.open` seam -- the same seam
  # the task uses -- and hand back every call it made so its options can be read.
  #
  # A URL THE `pages` HASH DOES NOT CARRY RAISES, because that is how NFL.com says
  # "not here": the task rescues OpenURI::HTTPError per candidate URL and moves on.
  # Built genuinely rather than doubled, since a double carrying only a message
  # would prove nothing about a rescue that reads the class.
  def run_task(pages: {})
    calls = []
    fake = lambda do |url, *rest, **kw|
      options = (rest.last.is_a?(Hash) ? rest.last : {}).merge(kw)
      calls << { url: url.to_s, options: options.transform_keys(&:to_s) }
      body = pages[url.to_s]
      raise http_error("404", "Not Found") unless body

      StringIO.new(body)
    end

    URI.stub(:open, fake) { Rake::Task[TASK].invoke }
    calls
  end

  def http_error(status, reason)
    io = StringIO.new("<html>Not Found</html>")
    io.extend(OpenURI::Meta)
    io.status = [status, reason]
    OpenURI::HTTPError.new("#{status} #{reason}", io)
  end

  # NFL.com's shape reduced to what the scrape actually reads: a card that is the
  # smallest ancestor of a coach link holding both a role label and an <img>. The
  # `t_lazy` transform is on the src on purpose -- it is Cloudinary's grayscale
  # placeholder, and the task's job is to replace it with the high-res stack.
  def bills_coaches_page
    <<~HTML
      <html><body>
        <div class="coach-card">
          <img src="https://static.clubs.nfl.com/image/upload/t_lazy/bills/mcdermott.jpg">
          <a href="https://www.buffalobills.com/team/coaches/sean-mcdermott/">Sean McDermott</a>
          <p>Head Coach</p>
        </div>
      </body></html>
    HTML
  end
end
