require "test_helper"

# WHICH BRANCH a GEM's release-candidate CI is read from.
#
# Ci::ProgressReader used to hard-code `GEM_CI_BRANCH = "main"` for every gem, on the
# written premise that "a GEM member has no `release` branch (two-rung ladder)". That
# premise was FALSE for every registered gem — studio-engine and solana-studio both
# declare `ladder: three-rung` in config/release_repos.yml and both answer
# `git ls-remote origin release`. A three-rung gem's version bump is pushed onto
# `release` by the sweep; `main` only takes it at G4 SHIP. So the G3 Assembling meter
# resolved the LAST SHIPPED commit's CI and rendered it as the CANDIDATE's verdict —
# a confident green describing a release that had already gone out.
#
# Every test here therefore seeds BOTH branches with DIFFERENT shas and lets the
# fixture map name which one was read: a green on the wrong branch is exactly the
# failure mode, so asserting "green" alone would not have caught the bug.
class Ci::ProgressReaderGemReleaseBranchTest < ActiveSupport::TestCase
  GEM_NWO = "McRitchie-Studio/studio-engine"
  GEM_REPO = "studio-engine"
  GEM_WORKFLOW = "Engine CI"

  FakeGemResponse = Struct.new(:code, :body, :headers) do
    def [](key) = headers[key] || headers[key.to_s.downcase]
  end

  setup do
    GithubWorkflowRun.delete_all
    CiCheckJob.delete_all
  end

  # ── The registry evidence the fix rests on ──────────────────────────────────

  # If this ever fails, the premise moved and the branch map must move with it —
  # better a red test than a meter that silently points at the wrong branch.
  test "[unit] both registered gems declare a three-rung ladder in the registry" do
    assert_equal %w[solana-studio studio-engine], Release::Repos.gem_repos.sort,
                 "the gem registry changed — re-check the ladder of any new gem"
    Release::Repos.gem_repos.each do |repo|
      assert_equal "three-rung", Release::Repos.ladder(repo),
                   "#{repo} is not three-rung; GEM_CI_BRANCHES must still name its candidate branch"
    end
  end

  test "[unit] every registered gem resolves a candidate branch (none fails closed by accident)" do
    Release::Repos.gem_repos.each do |repo|
      _nwo, branch, _workflow = Ci::ProgressReader.new.send(:ci_target_for, repo)
      assert_equal Release::BRANCH, branch,
                   "#{repo} is three-rung, so its candidate must be read from `release`"
    end
  end

  # ── The defect ──────────────────────────────────────────────────────────────

  test "[unit] a three-rung gem's release track reads `release`, not the shipped `main`" do
    reader = build_gem_reader(
      "engine-candidate" => { "passed" => 2, "failed" => 0, "pending" => 4 },
      "engine-last-ship" => { "passed" => 9, "failed" => 0, "pending" => 0 }
    )
    rel = release_with_gem
    # The candidate: the sweep's version bump, sitting on `release`, still running.
    seed_gem_run(branch: Release::BRANCH, sha: "engine-candidate")
    # The PREVIOUS SHIP on `main` — deliberately NEWER, so a branch-blind read would
    # prefer it, and fully green, so the wrong answer looks like a ready candidate.
    seed_gem_run(branch: "main", sha: "engine-last-ship", started_at: 5.minutes.from_now)

    progress = reader.for_release(rel)[GEM_REPO]

    assert_equal "2 / 6", progress.fraction_label,
                 "the Assembling meter must describe the candidate on `release`, not the last ship on `main`"
    assert_not_equal "9 / 9", progress.fraction_label,
                     "reading `main` reports an already-shipped commit as this candidate's verdict"
  end

  test "[unit] a two-rung gem keeps `main` — the fix is per-ladder, not a blanket swap" do
    reader = build_gem_reader(
      "two-rung-main"    => { "passed" => 7, "failed" => 0, "pending" => 1 },
      "stray-release-run" => { "passed" => 3, "failed" => 0, "pending" => 0 }
    )
    rel = release_with_gem
    seed_gem_run(branch: "main", sha: "two-rung-main")
    seed_gem_run(branch: Release::BRANCH, sha: "stray-release-run", started_at: 5.minutes.from_now)

    progress = Release::Repos.stub(:ladder, "two-rung") { reader.for_release(rel)[GEM_REPO] }

    assert_equal "7 / 8", progress.fraction_label,
                 "a gem with no `release` rung has its candidate on `main`, and must keep reading it"
  end

  # ── Failing closed ──────────────────────────────────────────────────────────

  test "[unit] a gem whose ladder names no candidate branch renders blank, never a guess" do
    reader = build_gem_reader(
      "dormant-main"    => { "passed" => 8, "failed" => 0, "pending" => 0 },
      "dormant-release" => { "passed" => 8, "failed" => 0, "pending" => 0 }
    )
    rel = release_with_gem
    seed_gem_run(branch: "main", sha: "dormant-main")
    seed_gem_run(branch: Release::BRANCH, sha: "dormant-release")

    progress, run_url = Release::Repos.stub(:ladder, "dormant") do
      [reader.for_release(rel)[GEM_REPO], reader.release_ci_run_url(rel, GEM_REPO)]
    end

    assert progress, "the slot must still exist so the live morph target pre-renders"
    assert_not progress.present?,
               "an undeclared ladder must read as NO DATA — both branches are seeded green, " \
               "so anything but blank means the reader picked one by guessing"
    assert_nil run_url, "an unresolvable track renders unlinked rather than pointing somewhere wrong"
  end

  test "[unit] a three-rung gem with no `release` run stays blank — it never falls back to `main`" do
    reader = build_gem_reader("engine-last-ship" => { "passed" => 9, "failed" => 0, "pending" => 0 })
    rel = release_with_gem
    # The `release` ref does not exist yet (or CI has not run on it). `main` is green.
    seed_gem_run(branch: "main", sha: "engine-last-ship")

    progress = reader.for_release(rel)[GEM_REPO]

    assert_not progress.present?,
               "no verdict beats a confident green read off the branch this candidate is NOT on"
  end

  # BACKEND DISCIPLINE: the ladder read touches config/release_repos.yml, so an
  # unreadable or malformed registry reaches this code path. It must not 500 the
  # board, must not GUESS a branch, and must not swallow the failure silently.
  test "[unit] an unreadable registry lands in ErrorLog and fails closed to a blank track" do
    reader = build_gem_reader("engine-last-ship" => { "passed" => 9, "failed" => 0, "pending" => 0 })
    rel = release_with_gem
    seed_gem_run(branch: "main", sha: "engine-last-ship")
    before = ErrorLog.count

    progress = nil
    Release::Repos.stub(:ladder, ->(_repo) { raise "malformed release_repos.yml" }) do
      assert_nothing_raised { progress = reader.for_release(rel)[GEM_REPO] }
    end

    assert_not progress.present?,
               "a registry we cannot read must yield NO verdict, not the green sitting on `main`"
    assert_equal before + 1, ErrorLog.count,
                 "an unlogged backend failure is invisible — the rescue must capture it"
  end

  # ── The app repos this must not disturb ─────────────────────────────────────

  test "[unit] an app repo still reads `release` and the plain CI workflow" do
    nwo, branch, workflow = Ci::ProgressReader.new.send(:ci_target_for, "turf-monster")

    assert_equal "McRitchie-Studio/turf-monster", nwo
    assert_equal Release::BRANCH, branch
    assert_equal GithubWorkflowRun::CI_WORKFLOW, workflow,
                 "the gem ladder rule must not reach the app branch of ci_target_for"
  end

  # ── The live path ───────────────────────────────────────────────────────────

  test "[unit] release_ci_slot_for morphs a gem on its `release` push, not its `main` push" do
    reader = build_gem_reader("engine-candidate" => { "passed" => 1, "failed" => 0, "pending" => 5 })
    rel = release_with_gem
    seed_gem_run(branch: Release::BRANCH, sha: "engine-candidate")

    repo, progress = reader.release_ci_slot_for(rel, GEM_NWO, Release::BRANCH)
    assert_equal GEM_REPO, repo
    assert_equal "1 / 6", progress.fraction_label

    assert_nil reader.release_ci_slot_for(rel, GEM_NWO, "main"),
               "a three-rung gem's `main` push is the SHIP lane, not its candidate track"
  end

  test "[unit] release_ci_slot_for fires nothing when the ladder names no branch" do
    reader = build_gem_reader
    rel = release_with_gem

    Release::Repos.stub(:ladder, "dormant") do
      assert_nil reader.release_ci_slot_for(rel, GEM_NWO, Release::BRANCH)
      assert_nil reader.release_ci_slot_for(rel, GEM_NWO, "main")
    end
  end

  # ── End to end: the three readers must agree on ONE run ─────────────────────

  # A page load (for_release), its next live tick (release_ci_slot_for) and the link
  # under the track (release_ci_run_url) all resolve the branch independently. If they
  # disagreed, the meter would show one commit and link another — so this walks all
  # three off the SAME ingested rows, with `main` seeded green and newer throughout.
  test "[integration] the meter, the live morph and the run link all resolve the release-branch run" do
    reader = build_gem_reader(
      "engine-candidate" => { "passed" => 4, "failed" => 0, "pending" => 2 },
      "engine-last-ship" => { "passed" => 9, "failed" => 0, "pending" => 0 }
    )
    rel = release_with_gem
    seed_gem_run(branch: Release::BRANCH, sha: "engine-candidate",
                 html_url: "https://github.com/McRitchie-Studio/studio-engine/actions/runs/RC")
    seed_gem_run(branch: "main", sha: "engine-last-ship", started_at: 5.minutes.from_now,
                 html_url: "https://github.com/McRitchie-Studio/studio-engine/actions/runs/SHIPPED")

    rendered = reader.for_release(rel)[GEM_REPO]
    _repo, morphed = reader.release_ci_slot_for(rel, GEM_NWO, Release::BRANCH)

    assert_equal "4 / 6", rendered.fraction_label
    assert_equal rendered.fraction_label, morphed.fraction_label,
                 "a page load and its next live tick must describe the same commit"
    assert_equal "https://github.com/McRitchie-Studio/studio-engine/actions/runs/RC",
                 reader.release_ci_run_url(rel, GEM_REPO),
                 "the track must link the run it drew, not the last ship's run"
  end

  # The consumer-lane fold is what the branch fix has to survive: a gem's track folds
  # EVERY declared suite lane on its SHA (it previews a workflow-blind gate), and those
  # sibling rows arrive keyed on repo+sha. Reading the wrong branch resolves the wrong
  # sha, so the fold silently lands on the shipped commit's rows too. This asserts the
  # fold happens on the CANDIDATE's rows, from live CiCheckJob rows and no API at all.
  test "[integration] a gem's lane fold lands on the release-branch sha, not the shipped one" do
    calls = 0
    reader = build_reader_with_executor do |_uri, _req|
      calls += 1
      FakeGemResponse.new("500", "the blind check-runs API must not be consulted here", {})
    end
    rel = release_with_gem
    seed_gem_run(branch: Release::BRANCH, sha: "rc-sha")
    seed_gem_run(branch: "main", sha: "shipped-sha", started_at: 5.minutes.from_now)
    # The CANDIDATE is mid-flight: its own suite is green but Consumer CI has failed,
    # which the pre-QA gate will refuse.
    seed_gem_job(sha: "rc-sha", workflow: GEM_WORKFLOW,  conclusion: "success")
    seed_gem_job(sha: "rc-sha", workflow: "Consumer CI", conclusion: "failure")
    # The SHIPPED commit is all green — the reading that made the bug invisible.
    3.times { seed_gem_job(sha: "shipped-sha", workflow: GEM_WORKFLOW, conclusion: "success") }

    progress = reader.for_release(rel)[GEM_REPO]

    assert_equal "1 / 2", progress.fraction_label, "both lanes on the CANDIDATE sha are folded"
    assert_equal :red, progress.state,
                 "the candidate's Consumer CI is red, so its track must not read ready"
    assert_equal 0, calls, "live rows only — the branch fix must not readmit the blind API"
  end

  private

  def build_gem_reader(fixtures = {})
    build_reader_with_executor(fixtures: fixtures) do |_uri, _req|
      FakeGemResponse.new("500", "no network in this test", {})
    end
  end

  def build_reader_with_executor(fixtures: nil, &executor)
    client = Github::Client.new(token: "t", logger: nil, sleeper: ->(_s) { }, max_retries: 0,
                                executor: executor)
    Ci::ProgressReader.new(client: client, cache: ActiveSupport::Cache::MemoryStore.new,
                           fixtures: fixtures)
  end

  def release_with_gem
    rel = Release.open!(branch: "release/gem-branch-#{SecureRandom.hex(3)}")
    Task.create!(title: "member #{GEM_REPO} #{SecureRandom.hex(2)}", stage: "reviewed",
                 position: 10, release_slug: rel.slug,
                 metadata: { "devops" => { "repositories" => [GEM_REPO] } })
    rel
  end

  def seed_gem_run(branch:, sha:, workflow: GEM_WORKFLOW, started_at: Time.current, html_url: nil)
    GithubWorkflowRun.create!(
      repo: GEM_NWO, workflow_name: workflow, run_id: SecureRandom.random_number(10**12),
      status: "in_progress", conclusion: nil, head_branch: branch, head_sha: sha,
      run_started_at: started_at, html_url: html_url
    )
  end

  def seed_gem_job(sha:, workflow:, conclusion:, status: "completed")
    CiCheckJob.create!(repo: GEM_NWO, job_id: SecureRandom.random_number(10**12), head_sha: sha,
                       head_branch: Release::BRANCH, workflow_name: workflow, status: status,
                       conclusion: conclusion, name: "#{workflow} #{SecureRandom.hex(3)}")
  end
end
