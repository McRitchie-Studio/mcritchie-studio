# frozen_string_literal: true

require "test_helper"

module Ci
  # The row's aggregation: which repos get a card, how parked work is counted,
  # and the sort that floats a card needing attention.
  class AppLadderTest < ActiveSupport::TestCase
    # --- which repos get a card ---------------------------------------------

    test "three_rung_repos is registry-derived and excludes dormant repos" do
      repos = Release::Repos.three_rung_repos

      assert_includes repos, "mcritchie-studio"
      assert_includes repos, "turf-monster"
      assert_includes repos, "studio-engine"
      assert_includes repos, "mcritchie-industries"

      # rolio is registered but `ladder: dormant` — it has no live rungs.
      refute_includes repos, "rolio", "a dormant repo has no ladder to report"
    end

    # THE RULE THIS ONCE ASSERTED, in the past tense: a three-rung repo mapping to nil
    # ("ships no suite workflow — declared, not overlooked") read `:none` on every rung,
    # and a card that could only say "not built" was judged noise, so it was excluded.
    # That is no longer the rule — see the reversal below.
    #
    # STUBBED rather than pointed at a live repo — a technique kept from #960, whose
    # reasoning still holds: a test that only runs while some real repo happens to be
    # CI-less is testing the registry, not the rule.
    #
    # THE RULE ITSELF IS REVERSED HERE, deliberately, per this task's acceptance
    # ("Row draws every three-rung repo including suiteless"). #960 asserted a
    # suiteless repo gets NO card, on the argument that three `not_built` rungs teach
    # the eye nothing. The counter-argument won: solana-studio sat `accepted` +1 ahead
    # of `release` with no task behind it, and the row could not show it because the
    # card did not exist. A card reading "not built" is a true statement about a repo
    # that ships without a suite; an absent card says nothing at all.
    #
    # No behaviour changes today either way — solana-studio declared "Gem CI" on
    # 2026-08-20, so every three-rung repo has a verdict and both rules draw the same
    # five cards. This is about which rule the next suiteless repo meets.
    test "reportable_repos draws a three-rung repo even when it declares no CI suite" do
      victim = Release::Repos.three_rung_repos.first
      assert victim.present?, "precondition: something is on the ladder"

      GithubWorkflowRun.stub(:ci_workflow_for, ->(repo) { repo == victim ? nil : "CI" }) do
        assert_includes Ci::AppLadder.reportable_repos, victim,
                        "a suiteless repo is still on the ladder, so it still gets a card"
        assert_equal Release::Repos.three_rung_repos.size,
                     Ci::AppLadder.reportable_repos.size,
                     "and no repo is dropped for lacking a suite"
      end
    end

    test "reportable_repos is exactly the repos that can report a verdict" do
      # solana-studio joined on 2026-08-20 — it grew a Rails engine, and with it
      # a "Gem CI" lane, so it now has a verdict to report.
      # turf-vault joined on 2026-08-31 — registering it in config/release_repos.yml
      # (to unblock a sweep its absence aborted) put it on the three-rung ladder, so
      # it draws a card. It resolves the plain "CI" workflow like any non-gem repo,
      # and its .github/workflows/ci.yml declares `name: CI`, so it has a real
      # verdict to report.
      assert_equal %w[mcritchie-industries mcritchie-studio solana-studio studio-engine turf-monster
                      turf-vault],
                   Ci::AppLadder.reportable_repos.sort
    end

    test "ladder reads the registry for a gem and for an app alike" do
      assert_equal "three-rung", Release::Repos.ladder("studio-engine")
      assert_equal "three-rung", Release::Repos.ladder("mcritchie-studio")
      assert_equal "dormant", Release::Repos.ladder("rolio")
      assert_nil Release::Repos.ladder("not-a-real-repo")
    end

    # --- parked counts: the clock that resets by derivation ------------------

    test "a task parks at the rung its merged stamp names" do
      Task.delete_all
      make_task(slug: "on-accepted", merged: Task::MERGED_ACCEPTED, repos: %w[turf-monster])
      make_task(slug: "on-release",  merged: Task::MERGED_RELEASE,  repos: %w[turf-monster])

      index = Ci::AppLadder.parked_index

      assert_equal 1, index.dig("turf-monster", "accepted")
      assert_equal 1, index.dig("turf-monster", "release")
    end

    # THE CLEAN SLATE. Shipped work has ARRIVED — nothing waits on main — so it must
    # not keep counting, or the card never goes quiet after a deployment. The hub sat
    # at "37 on main" indefinitely before this.
    test "shipped work does not park on main" do
      Task.delete_all
      make_task(slug: "already-shipped-one", merged: Task::MERGED_MAIN, repos: %w[turf-monster])
      make_task(slug: "already-shipped-two", merged: Task::MERGED_MAIN, repos: %w[turf-monster])

      assert_equal 0, Ci::AppLadder.parked_index.dig("turf-monster", "main")
      assert_empty Ci::AppLadder.parked_index, "a fully shipped repo parks nothing at all"
    end

    # …but work merged for the NEXT release is not residue and must keep showing.
    test "work waiting on accepted still counts right after a ship" do
      Task.delete_all
      make_task(slug: "shipped-last-cycle", merged: Task::MERGED_MAIN, repos: %w[turf-monster])
      make_task(slug: "queued-for-next", merged: Task::MERGED_ACCEPTED, repos: %w[turf-monster])

      assert_equal 1, Ci::AppLadder.parked_index.dig("turf-monster", "accepted")
      assert_equal 0, Ci::AppLadder.parked_index.dig("turf-monster", "main")
    end

    # This is the "clock starts over" behaviour, stated as a test: advancing to main
    # drains the lower rung AND adds nothing above it — the card falls silent.
    test "advancing a stamp to main empties the card" do
      Task.delete_all
      t = make_task(slug: "advancing", merged: Task::MERGED_ACCEPTED, repos: %w[turf-monster])

      assert_equal 1, Ci::AppLadder.parked_index.dig("turf-monster", "accepted")

      t.update!(merged: Task::MERGED_MAIN)

      assert_equal 0, Ci::AppLadder.parked_index.dig("turf-monster", "accepted"), "the lower rung drains"
      assert_equal 0, Ci::AppLadder.parked_index.dig("turf-monster", "main"), "and main never fills"
    end

    # `archived` is terminal and keeps its merged:"main" stamp forever. Counting it
    # would leave every main rung growing and never resetting.
    # The fixture is stamped ACCEPTED on purpose. Stamping it MERGED_MAIN would leave
    # PARKED_STAMP excluding it anyway, so the `archived` filter would never be
    # exercised and the guard would pass with the filter deleted — which is exactly
    # what happened in review: swapping `where.not(stage: "archived")` for `Task.all`
    # left all 21 tests green. An archived task at a COUNTED rung is the only shape
    # that can bite.
    test "an archived task at a counted rung is still excluded" do
      Task.delete_all
      make_task(slug: "archived-on-accepted", merged: Task::MERGED_ACCEPTED,
                repos: %w[turf-monster], stage: "archived")
      make_task(slug: "waiting-now", merged: Task::MERGED_ACCEPTED, repos: %w[turf-monster])

      assert_equal 1, Ci::AppLadder.parked_index.dig("turf-monster", "accepted"),
                   "archived work must not count, even at a rung that does"
    end

    test "an unstamped task parks nowhere" do
      Task.delete_all
      make_task(slug: "still-building", merged: nil, repos: %w[turf-monster], stage: "building")

      assert_empty Ci::AppLadder.parked_index
    end

    # --- multi-repo: a task is not "in" one of its repos ---------------------

    test "a multi-repo task parks on the rung in EVERY repo it names" do
      Task.delete_all
      make_task(slug: "spans-three", merged: Task::MERGED_ACCEPTED,
                repos: %w[mcritchie-studio turf-monster studio-engine])

      index = Ci::AppLadder.parked_index

      %w[mcritchie-studio turf-monster studio-engine].each do |repo|
        assert_equal 1, index.dig(repo, "accepted"), "#{repo} must count the shared task"
      end
    end

    # The key-name trap that bit several readers: the list lives at
    # devops.repositories. There is no devops.repos.
    test "repos_for reads devops.repositories and ignores a devops.repos lookalike" do
      assert_equal %w[turf-monster],
                   Ci::AppLadder.repos_for({ "devops" => { "repositories" => ["turf-monster"] } })

      assert_empty Ci::AppLadder.repos_for({ "devops" => { "repos" => ["turf-monster"] } })
    end

    test "repos_for tolerates a string, blanks, and a missing devops hash" do
      assert_equal %w[turf-monster], Ci::AppLadder.repos_for({ "devops" => { "repositories" => "turf-monster" } })
      assert_equal %w[turf-monster], Ci::AppLadder.repos_for({ "devops" => { "repositories" => ["turf-monster", "", " "] } })
      assert_empty Ci::AppLadder.repos_for({})
      assert_empty Ci::AppLadder.repos_for(nil)
    end

    # parked_index carries a COUNT and nothing else. It used to also track the newest
    # `updated_at` per rung, to support a staleness rule removed on 2026-08-20 — the
    # stamp is always written after the run starts, so the rule fired by construction.
    test "parked_index is counts only, with no timestamp to infer staleness from" do
      Task.delete_all
      make_task(slug: "one-on-accepted", merged: Task::MERGED_ACCEPTED, repos: %w[turf-monster])
      make_task(slug: "two-on-accepted", merged: Task::MERGED_ACCEPTED, repos: %w[turf-monster])

      assert_equal 2, Ci::AppLadder.parked_index.dig("turf-monster", "accepted")
    end

    # --- card shape and sorting ---------------------------------------------

    test "a card carries all three rungs in ladder order" do
      card = build_card(%i[green green green])

      assert_equal %w[accepted release main], card.rungs.map(&:branch)
    end

    test "a card needs attention when ANY rung does" do
      refute build_card(%i[green green green]).needs_attention?
      assert build_card(%i[green red green]).needs_attention?
      assert build_card(%i[conflicted green green]).needs_attention?
      refute build_card(%i[not_built green green]).needs_attention?,
             "an absent verdict is not an alarm"
    end

    test "cards sort worst-rung first" do
      clean = build_card(%i[green green green], repo: "clean-repo")
      running = build_card(%i[pending green green], repo: "running-repo")
      broken = build_card(%i[red green green], repo: "broken-repo")

      ordered = [clean, running, broken].sort_by(&:sort_key).map(&:repo)

      assert_equal %w[broken-repo running-repo clean-repo], ordered
    end

    test "gem? distinguishes the gem card from the app cards" do
      assert build_card(%i[green green green], repo: "studio-engine").gem?
      refute build_card(%i[green green green], repo: "turf-monster").gem?
    end


    # --- the broadcast trigger ---------------------------------------------

    # The row is pushed from the Task write itself rather than from
    # DeploymentsBroadcaster.release_modules, so it fires for a hand-run
    # `bin/task merged` that no release touched — and cannot double-push on a CI tick.
    test "a merged-stamp change broadcasts the ladder row" do
      Task.delete_all
      task = make_task(slug: "broadcast-on-stamp-change", merged: nil, repos: %w[turf-monster], stage: "building")

      calls = 0
      DeploymentsBroadcaster.stub(:app_ladder, -> { calls += 1 }) do
        task.update!(merged: Task::MERGED_ACCEPTED)
      end

      assert_equal 1, calls, "changing `merged` must push the row"
    end

    test "a stage change broadcasts the ladder row so archiving can drain a rung" do
      Task.delete_all
      task = make_task(slug: "broadcast-on-archive", merged: Task::MERGED_MAIN, repos: %w[turf-monster])

      calls = 0
      DeploymentsBroadcaster.stub(:app_ladder, -> { calls += 1 }) do
        task.update!(stage: "archived")
      end

      assert_equal 1, calls, "archiving drops the task off the main rung, so the row must move"
    end

    # The guard's whole job: a write that cannot move a rung must not push.
    test "an unrelated write does not broadcast the ladder row" do
      Task.delete_all
      task = make_task(slug: "broadcast-on-nothing", merged: Task::MERGED_ACCEPTED, repos: %w[turf-monster])

      calls = 0
      DeploymentsBroadcaster.stub(:app_ladder, -> { calls += 1 }) do
        task.update!(title: "Retitled Ladder Fixture Task")
      end

      assert_equal 0, calls, "a title edit changes no rung and must not push"
    end

    # --- position on the ladder ---------------------------------------------
    #
    # `furthest_rung` is the single derivation the whole track is drawn from, and the
    # one rule with a counter-intuitive shape: it reads the parked stamps from the FAR
    # END BACKWARD. An app routinely holds work at `accepted` (merged, awaiting the
    # sweep) AND at `release` (promoted, in QA) at the same moment, and the question the
    # track answers is how far the frontier GOT — not where the newest work sits.

    test "the frontier is read from the far end, so accepted work cannot hide a promotion" do
      card = build_card(%i[green green green], parked: { "accepted" => 2, "release" => 1 })

      assert_equal "release", card.furthest_rung,
        "work waiting at BOTH rungs means the frontier reached release; reading forward " \
        "would report accepted and draw the candidate as though it were never promoted"
      refute card.level?
    end

    test "nothing parked anywhere is ARRIVED, not unknown" do
      card = build_card(%i[green green green])

      assert_equal "main", card.furthest_rung,
        "main is deliberately absent from PARKED_STAMP because shipped work has LEFT " \
        "the ladder — an empty board means every rung drained"
      assert card.level?
    end

    test "work at accepted alone stops the frontier there" do
      card = build_card(%i[green green green], parked: { "accepted" => 3 })

      assert_equal "accepted", card.furthest_rung
    end

    # --- at rest, and the safety rule that outranks it ------------------------

    test "a drained non-member card is at rest" do
      card = build_card(%i[green green green])

      assert card.at_rest?
      assert_equal :at_rest, card.position
    end

    test "a RED rung is never at rest, however quiet the rest of the board" do
      card = build_card(%i[red green green])

      refute card.at_rest?,
        "dimming a card and sorting it last CLAIMS nothing here needs attention, and a " \
        "failing suite contradicts it"
      assert_equal :attention, card.position
    end

    test "a release member is never at rest even when drained" do
      card = build_card(%i[green green green], release_member: true)

      refute card.at_rest?, "a repo the open candidate moves is exactly what to watch"
      assert_equal :in_release, card.position
    end

    # THE REGRESSION, and the guard that pins it. #position used to derive rest from
    # level-and-not-a-member while #at_rest? ALSO demanded #quiet?, so the two could
    # disagree — and did, on a real board: studio-engine, drained and outside the
    # candidate but with its `release` suite mid-run, rendered the words "at rest" over
    # a live ticking CI meter.
    #
    # EXHAUSTIVE rather than by example. The disagreement lived in one combination out
    # of a small space, and an example test is exactly what missed it; sweeping the
    # space is what makes "these two can never disagree" a claim rather than a hope.
    test "position and at_rest? can never disagree, over every combination" do
      %i[green pending red not_built].repeated_permutation(3) do |states|
        [{}, { "accepted" => 1 }, { "release" => 1 }, { "accepted" => 1, "release" => 2 }].each do |parked|
          [true, false].each do |member|
            card = build_card(states, parked: parked, release_member: member)

            assert_equal card.at_rest?, card.position == :at_rest,
              "#{states.inspect} parked=#{parked.inspect} member=#{member}: " \
              "position=#{card.position} but at_rest?=#{card.at_rest?} — a card that " \
              "says one and does the other contradicts itself on screen"
          end
        end
      end
    end

    # The state the disagreement was hiding: drained and unclaimed, but still being
    # checked. Not rest (a suite in flight is live news), not queued (nothing waits).
    test "a drained unclaimed repo with a suite in flight is verifying, not resting" do
      card = build_card(%i[green pending green])

      assert_equal :verifying, card.position
      refute card.at_rest?
      assert card.level?, "nothing is waiting on a rung"
    end

    test "at rest sinks in the sort WITHOUT burying anything that needs attention" do
      resting = build_card(%i[green green green])
      waiting = build_card(%i[green green green], parked: { "accepted" => 1 })
      red     = build_card(%i[red green green])

      order = [resting, waiting, red].sort_by(&:sort_key)

      assert_equal [red, waiting, resting], order,
        "worst first, then work-waiting, and only genuinely idle cards sink"
    end

    # THE SINK, ISOLATED. The case above passes with or without the at-rest term,
    # because "work waiting beats idle" already separates those three — so it proves
    # the ordering, not the sink. These two cards have an IDENTICAL base key, leaving
    # the at-rest flag as the only thing that can order them.
    test "the at-rest flag alone decides between two otherwise identical cards" do
      resting = build_card(%i[green green green])
      member  = build_card(%i[green green green], release_member: true)

      assert_equal member.sort_key.drop(1), resting.sort_key.drop(1),
        "the base keys must be identical or this proves nothing"
      assert_equal [member, resting], [resting, member].sort_by(&:sort_key),
        "the at-rest card sinks below the member it would otherwise tie with"
    end

    test "a card with a PENDING rung is not at rest — a suite in flight is live news" do
      card = build_card(%i[pending green green])

      refute card.at_rest?
      refute card.quiet?
    end

    # --- the bar the view draws ----------------------------------------------
    #
    # Three segments reading as ONE progress bar. Colour carries `progress`, the glyph
    # carries `state`, and these tests hold CI constant so only progress can move.

    test "work waiting on accepted colours that rung and nothing beyond it" do
      track = build_card(%i[green pending green], parked: { "accepted" => 2 }).track

      assert_equal %w[accepted release main], track.map { |n| n[:branch] }
      assert_equal %i[here unreached unreached], track.map { |n| n[:progress] }
    end

    test "promotion turns the rung behind the work green and lights the candidate" do
      track = build_card(%i[green green green], parked: { "release" => 4 }).track

      assert_equal %i[passed here unreached], track.map { |n| n[:progress] }
    end

    # PARKED WORK WINS OVER THE FRONTIER. A plain "colour up to the frontier" rule
    # would paint `accepted` green here — saying "this rung is clear" over two tasks
    # that are still sitting on it.
    test "a rung holding work stays :here even when the frontier moved past it" do
      track = build_card(%i[green green green], parked: { "accepted" => 2, "release" => 4 }).track

      assert_equal %i[here here unreached], track.map { |n| n[:progress] }
    end

    # `main` IS ARRIVAL, NOT WAITING — nothing ever parks there, so reaching it reads
    # :passed. Were it :here, a fully drained app would end on an amber rung, which
    # says "still going" about work that has already shipped.
    test "a drained repo reads as three passes, never as work waiting on main" do
      track = build_card(%i[green green green]).track

      assert_equal %i[passed passed passed], track.map { |n| n[:progress] }
      refute_includes track.map { |n| n[:progress] }, :here
    end

    test "a rung carries its OWN verdict independently of where the work is" do
      card = build_card(%i[green red green], parked: { "accepted" => 1 })
      release = card.track.find { |n| n[:branch] == "release" }

      assert_equal :unreached, release[:progress], "no work has been promoted"
      assert_equal :red, release[:state],
        "progress and verdict are two different facts — a CI verdict on an EMPTY rung " \
        "is the normal resting shape of release between sweeps, and collapsing the two " \
        "into one channel is what made the old badge row unable to say where work was"
    end

    # --- the meter's rung -----------------------------------------------------
    #
    # MEASURED mid-sweep: the tracker panel read studio-engine ASSEMBLING green while
    # the card below it read ACCEPTED amber. Both were true, and the page still
    # contradicted itself.

    test "a release member's meter reports the RELEASE rung, not a stray running one" do
      card = build_card(%i[pending green green], release_member: true,
                                                 verdicts: { "release" => Time.current })

      assert_equal "release", card.active_rung.branch,
        "a task merging onto accepted mid-sweep must not steal the meter from the rung " \
        "the release is actually about"
    end

    test "a member whose release rung has NO verdict falls through rather than blanking" do
      card = build_card(%i[pending green green], release_member: true)

      assert_equal "accepted", card.active_rung.branch,
        "blanking the meter to 'no CI ingested' trades one wrong reading for a worse one"
    end

    test "a NON-member keeps the original rule — a running rung wins" do
      card = build_card(%i[pending green green],
                        verdicts: { "release" => Time.current })

      assert_equal "accepted", card.active_rung.branch,
        "a suite in flight is the live news and the only state an operator can act on"
    end

    # --- when each repo last reached production -------------------------------
    #
    # The at-rest card drops its meter, so this is the one fact it keeps. A quiet card
    # that says nothing at all is indistinguishable from a broken one.

    test "the shipped index reports each repo's newest production arrival" do
      old_rel = Release.create!(state: "shipped", branch: "release", shipped_at: 3.days.ago)
      new_rel = Release.create!(state: "shipped", branch: "release", shipped_at: 2.hours.ago)
      # THE NEWER TASK IS CREATED FIRST, deliberately. #shipped_index reads rows in id
      # order, so this puts the OLDER arrival last — and an implementation that simply
      # assigns as it walks (rather than keeping the max) answers with the older time
      # and fails here. Created the other way round, that bug passes by luck.
      make_task(slug: "shipped-recently-two", merged: Task::MERGED_MAIN, repos: %w[turf-monster],
                stage: "shipped").update!(release_slug: new_rel.slug)
      make_task(slug: "shipped-long-ago-one", merged: Task::MERGED_MAIN, repos: %w[turf-monster],
                stage: "shipped").update!(release_slug: old_rel.slug)

      index = Ci::AppLadder.shipped_index

      assert_in_delta new_rel.shipped_at.to_f, index["turf-monster"].to_f, 1,
        "the NEWEST arrival is the answer — an older release must not overwrite it"
    end

    # THE RELEASE'S OWN STAMP, not the task's `updated_at`, which moves again on every
    # later edit to an archived record.
    test "the shipped index reads the release stamp rather than the task's own clock" do
      release = Release.create!(state: "shipped", branch: "release", shipped_at: 5.days.ago)
      task = make_task(slug: "shipped-then-edited-later", merged: Task::MERGED_MAIN,
                       repos: %w[turf-monster], stage: "shipped")
      task.update!(release_slug: release.slug)
      task.touch

      assert_in_delta release.shipped_at.to_f, Ci::AppLadder.shipped_index["turf-monster"].to_f, 1
    end

    test "an unshipped release contributes nothing to the index" do
      release = Release.create!(state: "assembling", branch: "release")
      make_task(slug: "on-the-open-candidate", merged: Task::MERGED_RELEASE, repos: %w[turf-monster])
        .update!(release_slug: release.slug)

      assert_nil Ci::AppLadder.shipped_index["turf-monster"],
        "work on an open candidate has not reached production"
    end

    # A repo whose last ship predates the scanned window renders "shipped" with no
    # time rather than a wrong one — see SHIPPED_SCAN.
    test "the index is bounded and degrades to absent rather than to a wrong time" do
      assert_equal({}, Ci::AppLadder.shipped_index, "no shipped releases means no claims")
    end

    # --- membership, shared with the tracker panel ----------------------------

    # ONE derivation, two readers. The /deployments tracker lanes and the card's
    # at-rest rule both ask "is this repo in the open release", and two copies of that
    # is how the two halves of the page come to disagree about the same repo.
    test "member repos names every repo its members name, not just the primary" do
      release = Release.create!(state: "assembling", branch: "release")
      make_task(slug: "spans-two-repos-here", merged: Task::MERGED_RELEASE,
                repos: %w[studio-engine mcritchie-studio]).update!(release_slug: release.slug)

      assert_equal %w[studio-engine mcritchie-studio].sort, release.member_repos.sort,
        "a two-repo member is IN both of them — the singular #release_repo " \
        "under-reported a multi-repo release exactly as the pipeline under-promoted it"
    end

    private

    def build_card(states, repo: "turf-monster", parked: {}, verdicts: {}, release_member: false,
                   release_in_qa: false)
      rungs = Ci::AppLadder::RUNGS.each_with_index.map do |branch, i|
        Ci::LadderRung.new(repo: repo, branch: branch, state: states[i], sha: "abc1234def",
                           parked_count: parked[branch].to_i, verdict_at: verdicts[branch])
      end
      Ci::AppLadder::Card.new(repo: repo, rungs: rungs, release_member: release_member,
                              release_in_qa: release_in_qa)
    end

    # The board validates a 3-5 word title, so pad short fixture slugs rather than
    # fighting the rule — the title is irrelevant to every assertion here.
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
end
