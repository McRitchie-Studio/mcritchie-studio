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

    # solana-studio IS three-rung, but GEM_CI_WORKFLOWS maps it to nil ("ships no
    # suite workflow — declared, not overlooked"), so BranchGate fails closed and
    # every rung reads :none forever. A card that can only say "not built" is
    # noise; excluding it is derived from the registry, not hardcoded.
    test "reportable_repos drops a three-rung repo that declares no CI suite" do
      assert_includes Release::Repos.three_rung_repos, "solana-studio",
                      "precondition: solana-studio is on the ladder"
      assert_nil GithubWorkflowRun.ci_workflow_for("solana-studio"),
                 "precondition: solana-studio declares no suite"

      refute_includes Ci::AppLadder.reportable_repos, "solana-studio"
    end

    test "reportable_repos is exactly the four repos that can report a verdict" do
      assert_equal %w[mcritchie-industries mcritchie-studio studio-engine turf-monster],
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
      make_task(slug: "on-main",     merged: Task::MERGED_MAIN,     repos: %w[turf-monster])

      index = Ci::AppLadder.parked_index

      assert_equal 1, index.dig("turf-monster", "accepted")
      assert_equal 1, index.dig("turf-monster", "release")
      assert_equal 1, index.dig("turf-monster", "main")
    end

    # This is the "clock starts over" behaviour, stated as a test: a task that has
    # advanced to main no longer counts against accepted.
    test "advancing a stamp moves the task off the lower rung" do
      Task.delete_all
      t = make_task(slug: "advancing", merged: Task::MERGED_ACCEPTED, repos: %w[turf-monster])

      assert_equal 1, Ci::AppLadder.parked_index.dig("turf-monster", "accepted")

      t.update!(merged: Task::MERGED_MAIN)
      index = Ci::AppLadder.parked_index

      assert_equal 0, index.dig("turf-monster", "accepted"), "the lower rung drains to zero"
      assert_equal 1, index.dig("turf-monster", "main")
    end

    # `archived` is terminal and keeps its merged:"main" stamp forever. Counting it
    # would leave every main rung growing and never resetting.
    test "archived tasks are excluded so the main rung can drain" do
      Task.delete_all
      make_task(slug: "shipped-live", merged: Task::MERGED_MAIN, repos: %w[turf-monster])
      make_task(slug: "shipped-old", merged: Task::MERGED_MAIN, repos: %w[turf-monster], stage: "archived")

      assert_equal 1, Ci::AppLadder.parked_index.dig("turf-monster", "main")
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

    private

    def build_card(states, repo: "turf-monster")
      rungs = Ci::AppLadder::RUNGS.each_with_index.map do |branch, i|
        Ci::LadderRung.new(repo: repo, branch: branch, state: states[i], sha: "abc1234def")
      end
      Ci::AppLadder::Card.new(repo: repo, rungs: rungs)
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
