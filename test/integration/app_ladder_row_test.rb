# frozen_string_literal: true

require "test_helper"

# /deployments renders the app-ladder row, and renders it HONESTLY: the two states
# that exist to stop a stale or absent verdict reading as a pass must survive all
# the way to the markup, not just the model.
class AppLadderRowTest < ActionDispatch::IntegrationTest
  setup do
    Task.delete_all
    Activity.delete_all
    GithubWorkflowRun.delete_all
  end

  test "the deployments page renders the app ladder row" do
    get deployments_path

    assert_response :success
    assert_select "[data-test='app-ladder-row']", 1
    assert_select "[data-test='app-ladder-card']", minimum: 1
    assert_select "[data-test='app-ladder-suite']", minimum: 1
  end

  # THE PINNED STRIP SHIPS WITH THE ROW, inside #app-ladder-row — the slot
  # DeploymentsBroadcaster replaces. Rendered anywhere else it would keep showing a
  # verdict the row beneath it had already moved past, which on a board that takes live
  # updates is the one failure mode a pinned copy can have.
  test "the row carries a pinned strip with the same applications" do
    get deployments_path

    assert_select "[data-test='app-ladder-row'] [data-test='app-ladder-pinned']", 1

    repos = css_select("[data-test='app-ladder-card']").map { |el| el["data-repo"] }
    pinned = css_select("[data-test='app-ladder-pinned-card']").map { |el| el["data-repo"] }
    assert_equal repos, pinned, "the strip is the row's own applications, in the row's order"
  end

  test "every reportable repo gets exactly one card" do
    get deployments_path

    Ci::AppLadder.reportable_repos.each do |repo|
      assert_select "[data-test='app-ladder-card'][data-repo='#{repo}']", 1,
                    "#{repo} must have exactly one ladder card"
    end
  end

  test "a dormant repo gets no card" do
    get deployments_path

    assert_select "[data-test='app-ladder-card'][data-repo='rolio']", 0
  end

  # On the ladder and declaring a suite — so it earns a card like any other repo.
  # solana-studio was the standing no-card example until 2026-08-20, when it
  # shipped a Rails engine and a "Gem CI" lane; it now has a verdict to report.
  test "a three-rung repo that declares a CI suite gets a card" do
    get deployments_path

    assert_select "[data-test='app-ladder-card'][data-repo='solana-studio']", 1
  end

  # The no-card branch itself, which no live repo exercises any more. A repo
  # declaring no suite makes every rung read not_built forever, and a card that
  # can only say "not built" is noise — see Ci::AppLadder.reportable_repos.
  # STUBBED: the rule has to keep working for the next gem onboarded without a
  # suite, and borrowing the condition from live config stopped being possible.
  test "a three-rung repo with no declared CI suite gets no card" do
    kept = Ci::AppLadder.reportable_repos - ["solana-studio"]

    Ci::AppLadder.stub(:reportable_repos, kept) do
      get deployments_path

      assert_select "[data-test='app-ladder-card'][data-repo='solana-studio']", 0
      assert_select "[data-test='app-ladder-card'][data-repo='turf-monster']", 1,
                    "and the repos that DO declare a suite still get theirs"
    end
  end

  test "each card carries all three rungs" do
    get deployments_path

    assert_select "[data-test='app-ladder-card'][data-repo='turf-monster']" do
      %w[accepted release main].each do |branch|
        assert_select "[data-test='app-ladder-rung'][data-branch='#{branch}']", 1
      end
    end
  end

  # With nothing ingested, every rung must read not_built — never green. This is
  # the empty-board case, and a card that greened here would be asserting a pass
  # from an absence.
  test "with no ingested CI every rung reads not_built rather than green" do
    get deployments_path

    assert_select "[data-test='app-ladder-rung'][data-state='not_built']", minimum: 3
    assert_select "[data-test='app-ladder-rung'][data-state='green']", 0,
                  "an absent verdict must never render as green"
  end

  test "parked work is counted onto the rung its stamp names" do
    make_task(slug: "parked-on-accepted-one", merged: Task::MERGED_ACCEPTED, repos: %w[turf-monster])
    make_task(slug: "parked-on-accepted-two", merged: Task::MERGED_ACCEPTED, repos: %w[turf-monster])

    get deployments_path

    assert_response :success
    assert_select "[data-test='app-ladder-card'][data-repo='turf-monster'][data-furthest='accepted']" do
      assert_select "[data-test='app-ladder-parked'][data-branch='accepted']", text: "2"
      assert_select "[data-test='app-ladder-rung'][data-branch='accepted'][data-progress='here']", 1
      assert_select "[data-test='app-ladder-rung'][data-branch='release'][data-progress='unreached']", 1
    end
  end

  # THE CLEAN SLATE. Once work ships, the card goes quiet: the accepted rung drains
  # and main never fills, because shipped work has ARRIVED rather than parked. All
  # derived from the stamp, so there is nothing to clear by hand.
  test "advancing a task to main empties the card" do
    task = make_task(slug: "advances-to-production", merged: Task::MERGED_ACCEPTED, repos: %w[turf-monster])

    get deployments_path
    assert_select "[data-test='app-ladder-card'][data-repo='turf-monster'][data-position='queued']" do
      assert_select "[data-test='app-ladder-parked'][data-branch='accepted']", 1
    end

    task.update!(merged: Task::MERGED_MAIN)

    get deployments_path
    assert_select "[data-test='app-ladder-card'][data-repo='turf-monster'][data-furthest='main']" do
      assert_select "[data-test='app-ladder-parked']", 0,
                    "the accepted rung must drain when the stamp advances, and shipped " \
                    "work must not re-park on main"
      assert_select "[data-test='app-ladder-at-rest']", 1,
                    "the drained card goes to rest and states its ship there"
      assert_select "[data-test='app-ladder-rung'][data-progress='passed']", 3,
                    "with nothing waiting anywhere the whole bar reads green"
    end
  end

  # THE BLUE-BOX ASK, END TO END. A drained repo outside the open candidate recedes:
  # it dims, drops its meter and sorts behind the cards that still hold work.
  test "a drained repo outside the release goes to rest and sinks in the row" do
    make_task(slug: "still-waiting-on-accepted", merged: Task::MERGED_ACCEPTED, repos: %w[turf-monster])

    get deployments_path

    assert_select "[data-test='app-ladder-card'][data-repo='turf-monster'][data-at-rest='false']", 1
    assert_select "[data-test='app-ladder-card'][data-repo='solana-studio'][data-at-rest='true']", 1
    assert_select "[data-test='app-ladder-card'][data-repo='solana-studio'] [data-test='app-ladder-at-rest']", 1

    repos = css_select("[data-test='app-ladder-card']").map { |el| el["data-repo"] }
    assert repos.index("turf-monster") < repos.index("solana-studio"),
           "a card still holding work must sort ahead of a resting one"
  end

  # A repo the OPEN CANDIDATE moves is live work however empty its rungs, so it keeps
  # the full card — the tracker panel above the row is drawing lanes for it.
  test "a repo in the open release does not rest" do
    task = make_task(slug: "member-of-open-release", merged: Task::MERGED_ACCEPTED, repos: %w[solana-studio])
    release = Release.open!
    task.update!(release_slug: release.slug, merged: Task::MERGED_RELEASE)

    get deployments_path

    assert_select "[data-test='app-ladder-card'][data-repo='solana-studio'][data-position='in_release']", 1
    assert_select "[data-test='app-ladder-card'][data-repo='solana-studio'] [data-test='app-ladder-at-rest']", 0
  end

  test "a card needing attention is marked for the operator" do
    get deployments_path

    assert_response :success
    # not_built is not an attention state, so a bare board marks nothing.
    assert_select "[data-test='app-ladder-card'][data-attention='true']", 0
  end

  # --- the review roll ------------------------------------------------------

  # EVERY card carries the review block, including the quiet repos — a card that
  # renders nothing here reads as "no reviews take any time", which is not a claim
  # this board should be able to make by omission.
  test "every card carries a review average or says it has none" do
    get deployments_path

    assert_response :success
    Ci::AppLadder.reportable_repos.each do |repo|
      assert_select "[data-test='app-ladder-review'][data-repo='#{repo}']", 1
      assert_select "[data-test='app-ladder-card'][data-repo='#{repo}'] [data-test='app-ladder-review-note']", 1
    end
  end

  test "an app with no measured review renders the empty state, not a blank" do
    get deployments_path

    assert_select "[data-test='app-ladder-card'][data-repo='solana-studio']" do
      assert_select "[data-test='app-ladder-review-value']", text: "not enough data"
      assert_select "[data-test='app-ladder-review-note']", text: "no reviews measured yet"
    end
  end

  # The whole feature end to end: two clean reviews and two the rules drop, rendered
  # as an average with the count of what it dropped beside it.
  test "the card renders the average and the excluded count" do
    reviewed_task(slug: "roll-clean-one", repo: "turf-monster", minutes: 10, at: 1.hour.ago)
    reviewed_task(slug: "roll-clean-two", repo: "turf-monster", minutes: 20, at: 2.hours.ago)
    reviewed_task(slug: "roll-was-blocked", repo: "turf-monster", minutes: 5, at: 3.hours.ago, blocked: true)
    reviewed_task(slug: "roll-too-long", repo: "turf-monster", minutes: 90, at: 4.hours.ago)

    get deployments_path

    assert_response :success
    assert_select "[data-test='app-ladder-card'][data-repo='turf-monster']" do
      assert_select "[data-test='app-ladder-review-value']", text: "15m avg"
      assert_select "[data-test='app-ladder-review-note']", text: "over 2 reviews · 2 of 4 excluded"
    end
  end

  # LIVE, NOT CACHED AT DEPLOY. The average must move as reviews land — no
  # production-deploy caching pass in the loop.
  test "a review that lands moves the average on the next render" do
    reviewed_task(slug: "roll-first-one", repo: "turf-monster", minutes: 10, at: 2.hours.ago)

    get deployments_path
    assert_select "[data-test='app-ladder-card'][data-repo='turf-monster'] [data-test='app-ladder-review-value']",
                  text: "10m avg"

    reviewed_task(slug: "roll-second-one", repo: "turf-monster", minutes: 20, at: 1.hour.ago)

    get deployments_path
    assert_select "[data-test='app-ladder-card'][data-repo='turf-monster'] [data-test='app-ladder-review-value']",
                  { text: "15m avg" }, "the new review must be in the average with no cache pass"
  end

  # THE WHOLE CHAIN, with nothing hand-written. A real g2a_primary gate run opens and
  # closes, the task then transitions to `reviewed`, and the average appears — proving
  # the two ends of the measurement are the ones the operator chose:
  #
  #   start  = the review crew's FIRST claim (the gate attempt's started_at)
  #   finish = the PR merging onto `accepted` (the `reviewed` transition, per the
  #            pipeline invariant that `reviewed` ⟺ code-on-accepted)
  #
  # Nothing here writes testing_phases by hand — Task#refresh_testing_phases_after_change
  # builds it off the transition, which is also what makes the number LIVE.
  test "a real review span reaches the card without anything hand-written" do
    travel_to Time.zone.parse("2026-08-25 12:00:00") do
      task = make_task(slug: "measured-end-to-end", merged: nil, repos: %w[turf-monster], stage: "submitted")

      GateRun.open!(subject_type: "task", subject_slug: task.slug, key: "g2a_primary",
                    now: Time.current - 14.minutes)
      GateRun.close!(subject_type: "task", subject_slug: task.slug, key: "g2a_primary",
                     success: true, now: Time.current - 1.minute)

      # The merge lands: review moves the task to `reviewed` and stamps it.
      task.update!(stage: "reviewed", merged: Task::MERGED_ACCEPTED)

      get deployments_path

      assert_response :success
      assert_select "[data-test='app-ladder-card'][data-repo='turf-monster'] [data-test='app-ladder-review-value']",
                    { text: "14m avg" },
                    "first claim to merge is 14 minutes, and that is what the card must say"
    end
  end

  # --- the board's batched reads --------------------------------------------

  # THE N+1 GUARD, stated as a contract rather than a query count: if any card were
  # fetching its own roll, this stub would be reached and the page would blow up.
  # (Mutation-checked: swap Ci::AppLadder.build back to a per-card
  # Review::DurationRoll.for and this test goes red.)
  test "the row reads every roll in one batch, never per card" do
    Review::DurationRoll.stub(:for, ->(*) { raise "a card fetched its own review roll" }) do
      get deployments_path

      assert_response :success
      assert_select "[data-test='app-ladder-review']", minimum: 1
    end
  end

  # THE SAME BUG ONE ROW DOWN, and it was live: /deployments calls load_board (so
  # @local_check_by_slug is populated) but its card render did not pass it, and
  # tasks/_task_card falls back to Cert::LocalCheckReader#for_task per card — a
  # GateRun query for every building card with no PR yet. tasks/_board always passed
  # the batch; this row now matches.
  test "the deploy board reads local checks in one batch, not one per card" do
    building_task("mid-cert-alpha")
    one_card = gate_run_queries { get deployments_path }
    assert_response :success

    3.times { |i| building_task("mid-cert-extra-#{i}") }
    four_cards = gate_run_queries { get deployments_path }
    assert_response :success

    assert_equal one_card, four_cards,
                 "four building cards must cost what one costs — the batch is already " \
                 "computed by load_board, so the card must never fall back to for_task"
  end

  private

  # A `building` task with no PR — the shape whose card reads a local check.
  def building_task(slug)
    Task.create!(slug: slug, title: "Local Check Fixture #{slug.split('-').last.capitalize}",
                 stage: "building",
                 metadata: { "devops" => { "repositories" => %w[turf-monster] } })
  end

  # How many gate_runs SELECTs the render issued. The board reads them a FIXED number
  # of times whatever the card count — the load_board preload plus the one batched
  # Cert::LocalCheckReader#for_tasks — while the per-card fallback adds one read per
  # card. So the count is flat when the batch is wired and grows when it is not.
  #
  # MATCH ON `FROM "gate_runs"`, not on the gate key: these run as PREPARED
  # STATEMENTS, so "g1_cert" is a bind value and never appears in the SQL text. A
  # filter looking for it counts zero every time and the guard passes on a board that
  # is querying per card — which is exactly how the first draft of this test went
  # green against a deliberately broken view.
  def gate_run_queries
    count = 0
    counter = ->(_name, _start, _finish, _id, payload) do
      next if payload[:cached] || payload[:name].to_s == "SCHEMA"

      count += 1 if payload[:sql].to_s.include?(%(FROM "gate_runs"))
    end
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end

  # A task carrying a COMPLETED review span — what Review::DurationRoll reads.
  # testing_phases is written with update_columns AFTER create because creating the
  # task fires Task#refresh_testing_phases_after_change, which would recompute it.
  def reviewed_task(slug:, repo:, minutes:, at:, blocked: false)
    task = make_task(slug: slug, merged: Task::MERGED_ACCEPTED, repos: [repo])
    seconds = minutes * 60
    task.update_columns(
      testing_phases: {
        "cache_version" => Task::TestingPhases::VERSION,
        "phases" => { "review" => { "status" => "completed", "seconds" => seconds,
                                    "started_at" => (at - seconds).iso8601,
                                    "completed_at" => at.iso8601, "source" => "gate_run" } }
      },
      testing_phases_version: Task::TestingPhases::VERSION
    )
    Activity.create!(task_slug: slug, activity_type: "qa_feedback", description: "sent back") if blocked
    task
  end

  def make_task(slug:, merged:, repos:, stage: "reviewed")
    words = slug.tr("-", " ").titleize.split
    words += %w[Ladder Fixture Task] while words.length < 3
    Task.create!(
      slug: slug,
      title: words.first(5).join(" "),
      stage: stage,
      merged: merged,
      metadata: { "devops" => { "repositories" => repos } }
    )
  end
end
