require "test_helper"
require "minitest/mock"

class Release::ConductorTest < ActiveSupport::TestCase
  # A reviewed task with a KNOWN app repo. Repo-aware eligibility (see
  # validate_members!) refuses a member whose repo is in neither registry
  # section, so the default member here must classify to a known kind. The label
  # is wrapped into a 3-5 word title so it satisfies the naming-discipline rule.
  def reviewed_task(label = "default", repo: "mcritchie-studio")
    Task.create!(title: "reviewable #{label} demo task", stage: "reviewed",
                 metadata: { "devops" => { "shape" => "backend", "repositories" => [repo] } })
  end

  test "prepare! opens a new release when none is active and assembles it" do
    t = reviewed_task
    rel = Release::Conductor.prepare!(task_slugs: [t.slug], slug: "rel-test-new")

    assert_equal "rel-test-new", rel.slug
    assert_equal "release", rel.branch # the persistent per-repo release branch
    assert_equal "assembled", rel.state
    assert_equal "assembled", t.reload.stage
    assert_includes rel.tasks.pluck(:slug), t.slug
  end

  # --- adopt! (membership-at-merge: PR merged INTO `release`) ---

  test "adopt! records membership, flips the task to assembled, opens a release if none" do
    assert_nil Release.current
    t = reviewed_task
    rel = Release::Conductor.adopt!(t)

    assert_equal rel, Release.current
    assert_equal "assembling", rel.state # adopt! records membership; prepare! assembles
    assert_equal "assembled", t.reload.stage
    assert_includes rel.tasks.pluck(:slug), t.slug
  end

  test "adopt! attaches to the existing active release" do
    first = reviewed_task("first")
    rel = Release::Conductor.adopt!(first)
    Release::Conductor.adopt!(reviewed_task("second"))

    assert_equal 2, rel.reload.tasks.count
  end

  test "adopt! is idempotent — re-adopting the same task is a no-op" do
    t = reviewed_task
    rel = Release::Conductor.adopt!(t)
    again = Release::Conductor.adopt!(t)

    assert_equal rel.id, again.id
    assert_equal 1, again.tasks.count
  end

  test "adopt! reopens an assembled RC so a late merge re-QAs" do
    rel = Release::Conductor.prepare!(task_slugs: [reviewed_task("first").slug])
    assert_equal "assembled", rel.state

    Release::Conductor.adopt!(reviewed_task("late"))

    assert_equal "assembling", rel.reload.state # reopened to re-assemble + re-QA
    assert_equal 2, rel.tasks.count
  end

  test "adopt! raises on a task that is not reviewed" do
    designed = Task.create!(title: "designed task not reviewed") # stage: designed
    assert_raises(ArgumentError) { Release::Conductor.adopt!(designed) }
  end

  test "prepare! is additive — extends the active release instead of opening a second" do
    first = reviewed_task("first")
    rel1 = Release::Conductor.prepare!(task_slugs: [first.slug], slug: "rel-test-a")

    second = reviewed_task("second")
    rel2 = Release::Conductor.prepare!(task_slugs: [second.slug], slug: "rel-test-b") # slug ignored: active exists

    assert_equal rel1.id, rel2.id
    assert_equal "rel-test-a", rel2.slug
    assert_equal 2, rel2.tasks.count
    assert_equal "assembled", rel2.state
  end

  test "prepare! reopens an assembled RC to absorb new work, then re-assembles" do
    rel = Release::Conductor.prepare!(task_slugs: [reviewed_task("first").slug])
    assert_equal "assembled", rel.state

    again = Release::Conductor.prepare!(task_slugs: [reviewed_task("second").slug])

    assert_equal rel.id, again.id
    assert_equal 2, again.tasks.count
    assert_equal "assembled", again.reload.state
  end

  test "prepare! skips tasks already on the release (idempotent)" do
    t = reviewed_task
    Release::Conductor.prepare!(task_slugs: [t.slug])
    rel = Release::Conductor.prepare!(task_slugs: [t.slug])

    assert_equal 1, rel.tasks.count
  end

  test "prepare! raises on a task that is not reviewed" do
    designed = Task.create!(title: "designed task not reviewed") # stage: designed
    assert_raises(ArgumentError) { Release::Conductor.prepare!(task_slugs: [designed.slug]) }
  end

  test "prepare! is atomic — a non-reviewed task rolls back the new release" do
    designed = Task.create!(title: "designed task not reviewed")
    assert_raises(ArgumentError) { Release::Conductor.prepare!(task_slugs: [designed.slug]) }
    assert_equal 0, Release.count, "a failed prepare! must not leave a dangling release"
  end

  test "prepare! no longer auto-adds reviewed work — nothing active + no --task is a no-op" do
    a = reviewed_task("a")
    b = reviewed_task("b")

    # Membership now flips at PR-merge time (adopt!), not here — with nothing
    # active and no explicit curation there's nothing to prepare.
    assert_nil Release::Conductor.prepare!(task_slugs: [])
    assert_equal 0, Release.count
    assert_equal %w[reviewed reviewed], [a.reload.stage, b.reload.stage]
  end

  test "prepare! assembles the active release without pulling in uncurated reviewed work" do
    member = reviewed_task("member")
    Release::Conductor.adopt!(member) # merged into release
    bystander = reviewed_task("bystander") # reviewed but never merged

    rel = Release::Conductor.prepare!(task_slugs: [])

    assert_equal "assembled", rel.state
    assert_equal [member.slug], rel.tasks.pluck(:slug)
    assert_equal "reviewed", bystander.reload.stage, "an uncurated reviewed task must not ride the release"
  end

  test "prepare! is idempotent against an already-assembled RC" do
    rel = Release::Conductor.prepare!(task_slugs: [reviewed_task.slug])
    assert_equal "assembled", rel.state

    again = Release::Conductor.prepare!(task_slugs: [])

    assert_equal rel.id, again.id
    assert_equal "assembled", again.state
  end

  test "ship! stamps the deployed sha + url and flips the RC and members to shipped" do
    t = reviewed_task
    rel = Release::Conductor.prepare!(task_slugs: [t.slug])

    Release::Conductor.ship!(release: rel, deployed_sha: "abc1234", by: "alex", production_url: "https://example.test")

    assert_equal "shipped", rel.reload.state
    assert_equal "abc1234", rel.deployed_sha
    assert_equal "https://example.test", rel.production_url
    assert_equal "alex", rel.confirmed_by
    assert_equal "shipped", t.reload.stage
  end

  test "eligible_task_slugs lists reviewed tasks" do
    a = reviewed_task("a")
    b = reviewed_task("b")
    slugs = Release::Conductor.eligible_task_slugs

    assert_includes slugs, a.slug
    assert_includes slugs, b.slug
  end

  # --- producer-first ordering + member_plan ---

  def gem_task(label = "engine", repo: "studio-engine")
    Task.create!(title: "gem #{label} release task", stage: "reviewed",
                 metadata: { "devops" => { "shape" => "library", "repositories" => [repo] } })
  end

  def app_task(label = "app", repo: "mcritchie-studio", branch: "feat/x", deps: [])
    Task.create!(title: "app #{label} release task", stage: "reviewed", dependencies: deps,
                 metadata: { "devops" => {
                   "shape" => "backend", "repositories" => [repo], "branch" => branch,
                   "pr_url" => "https://github.com/amcritchie/#{repo}/pull/1"
                 } })
  end

  test "prepare! adds members producer-first — the gem gets the earlier position" do
    app = app_task("consumer")
    gem = gem_task("engine")
    rel = Release::Conductor.prepare!(task_slugs: [app.slug, gem.slug]) # app passed first

    assert_equal [gem.slug, app.slug], rel.tasks.order(:position).pluck(:slug)
  end

  test "member_plan is producer-first and tags kind/repo/branch/version" do
    gem = gem_task("engine", repo: "studio-engine")
    app = app_task("consumer", repo: "mcritchie-studio", branch: "feat/consume")
    rel = Release::Conductor.prepare!(task_slugs: [gem.slug, app.slug])

    plan = nil
    Release::Repos.stub(:gem_version, ->(repo) { repo == "studio-engine" ? "9.9.9" : nil }) do
      plan = Release::Conductor.member_plan(rel)
    end

    assert_equal [gem.slug, app.slug], plan.map { |m| m[:slug] }
    gem_member, app_member = plan

    assert_equal "gem", gem_member[:kind]
    assert_equal "studio-engine", gem_member[:repo]
    assert_equal "9.9.9", gem_member[:version]
    assert_nil gem_member[:branch]

    assert_equal "app", app_member[:kind]
    assert_equal "mcritchie-studio", app_member[:repo]
    assert_equal "feat/consume", app_member[:branch]
    assert_nil app_member[:version]
  end

  test "ordered_members puts gems before apps regardless of position" do
    rel = Release.open!
    app = app_task("consumer", repo: "mcritchie-studio", branch: "feat/app")
    gem = gem_task("engine", repo: "studio-engine")
    rel.add(app)
    rel.add(gem)
    app.update!(position: 0)
    gem.update!(position: 99) # later position, but a producer → still first

    assert_equal [gem.slug, app.slug], rel.ordered_members.map(&:slug)
  end

  test "ordered_members honors dependencies even against position order" do
    rel = Release.open!
    base = app_task("base", repo: "turf-monster", branch: "feat/base")
    dependent = app_task("dependent", repo: "turf-monster", branch: "feat/dep", deps: [base.slug])
    rel.add(base)
    rel.add(dependent)
    # Force positions so position ALONE would put the dependent first.
    dependent.update!(position: 0)
    base.update!(position: 99)

    assert_equal [base.slug, dependent.slug], rel.ordered_members.map(&:slug),
                 "a task must sort after any task in its dependencies"
  end

  # --- repo_plan: per-repo deploy plan ---

  test "repo_plan groups members by repo, producer-first, with per-repo deploy metadata" do
    gem = gem_task("engine", repo: "studio-engine")
    studio = app_task("studio change", repo: "mcritchie-studio", branch: "feat/studio")
    turf = app_task("turf change", repo: "turf-monster", branch: "feat/turf")
    rel = Release::Conductor.prepare!(task_slugs: [turf.slug, studio.slug, gem.slug], slug: "rel-multi-repo")

    plan = nil
    Release::Repos.stub(:gem_version, ->(repo) { repo == "studio-engine" ? "0.9.0" : nil }) do
      plan = Release::Conductor.repo_plan(rel)
    end

    # Producer-first repo order: the gem repo leads, then apps in member order.
    assert_equal %w[studio-engine mcritchie-studio turf-monster], plan.map { |g| g[:repo] }

    gem_group = plan.find { |g| g[:repo] == "studio-engine" }
    assert_equal :gem, gem_group[:kind]
    assert_equal [gem.slug], gem_group[:members].map { |m| m[:slug] }
    assert_nil gem_group[:release_branch]
    assert_nil gem_group[:qa_app]
    assert_nil gem_group[:prod_deploy]

    studio_group = plan.find { |g| g[:repo] == "mcritchie-studio" }
    assert_equal :app, studio_group[:kind]
    assert_equal [studio.slug], studio_group[:members].map { |m| m[:slug] }
    assert_equal "release", studio_group[:release_branch] # the persistent per-repo branch
    assert_equal "mcritchie-studio", studio_group[:qa_app]
    assert_equal "git_push_heroku", studio_group[:prod_deploy]["strategy"]

    turf_group = plan.find { |g| g[:repo] == "turf-monster" }
    assert_equal :app, turf_group[:kind]
    assert_equal "release", turf_group[:release_branch]
    assert_equal "turf-monster", turf_group[:qa_app]
    assert_equal "repo_script", turf_group[:prod_deploy]["strategy"]
    assert_equal ["--yes"], turf_group[:prod_deploy]["args"]
  end

  test "repo_plan collapses multiple members of one repo into a single group" do
    a = app_task("turf a", repo: "turf-monster", branch: "feat/a")
    b = app_task("turf b", repo: "turf-monster", branch: "feat/b")
    rel = Release::Conductor.prepare!(task_slugs: [a.slug, b.slug], slug: "rel-one-repo")

    plan = Release::Conductor.repo_plan(rel)

    assert_equal 1, plan.length
    assert_equal "turf-monster", plan.first[:repo]
    assert_equal [a.slug, b.slug].sort, plan.first[:members].map { |m| m[:slug] }.sort
  end

  test "repo_plan is JSON-serializable" do
    gem = gem_task("engine", repo: "studio-engine")
    app = app_task("consumer", repo: "turf-monster", branch: "feat/consume")
    rel = Release::Conductor.prepare!(task_slugs: [gem.slug, app.slug], slug: "rel-json")

    plan = nil
    Release::Repos.stub(:gem_version, ->(_repo) { "0.9.0" }) do
      plan = Release::Conductor.repo_plan(rel)
    end

    assert_nothing_raised { JSON.generate(plan) }
  end

  # --- repo-aware eligibility ---

  test "prepare! raises naming a member whose repo is in neither registry section" do
    mystery = Task.create!(title: "mystery repo deploy task", stage: "reviewed",
                           metadata: { "devops" => { "shape" => "backend", "repositories" => ["mystery-repo"] } })

    err = assert_raises(ArgumentError) { Release::Conductor.prepare!(task_slugs: [mystery.slug]) }
    assert_match mystery.slug, err.message
    assert_match "mystery-repo", err.message
  end

  test "prepare! eligibility is atomic — an unknown-repo member rolls the release back" do
    mystery = Task.create!(title: "mystery repo deploy task", stage: "reviewed",
                           metadata: { "devops" => { "shape" => "backend", "repositories" => ["mystery-repo"] } })

    assert_raises(ArgumentError) { Release::Conductor.prepare!(task_slugs: [mystery.slug]) }
    assert_equal 0, Release.count, "an unknown-repo member must not leave a dangling release"
    assert_equal "reviewed", mystery.reload.stage, "the rolled-back task stays reviewed"
  end

  # --- record_qa_deploy ---

  test "record_qa_deploy stores the qa_url on the release" do
    rel = Release::Conductor.prepare!(task_slugs: [reviewed_task.slug])
    Release::Conductor.record_qa_deploy(release: rel, qa_url: "https://qa.example.test")
    assert_equal "https://qa.example.test", rel.reload.qa_url
  end

  # --- record_qa_shas ---

  test "record_qa_shas persists the per-repo deployed SHAs onto the release" do
    rel = Release::Conductor.prepare!(task_slugs: [reviewed_task.slug])
    Release::Conductor.record_qa_shas(release: rel, shas: { "mcritchie-studio" => "abc1234", "turf-monster" => "def5678" })

    assert_equal({ "mcritchie-studio" => "abc1234", "turf-monster" => "def5678" }, rel.reload.metadata["qa_shas"])
  end

  # --- post_release_notes (reuses ReleaseNotes::Formatter + DiscordClient) ---

  def shipped_release
    rel = Release::Conductor.prepare!(task_slugs: [reviewed_task.slug])
    Release::Conductor.ship!(release: rel, deployed_sha: "abc1234", by: "alex", production_url: "https://example.test")
    rel
  end

  test "post_release_notes builds a message and delivers it" do
    rel = shipped_release
    delivered = nil
    ReleaseNotes::DiscordClient.stub(:deliver, ->(content:) { delivered = content }) do
      result = Release::Conductor.post_release_notes(release: rel)
      assert result[:delivered]
      assert result[:message].present?
    end
    assert delivered.present?, "DiscordClient.deliver should have been called"
  end

  test "post_release_notes dry_run builds the message without delivering" do
    rel = shipped_release
    called = false
    ReleaseNotes::DiscordClient.stub(:deliver, ->(content:) { called = true }) do
      result = Release::Conductor.post_release_notes(release: rel, dry_run: true)
      assert_not result[:delivered]
      assert result[:message].present?
    end
    assert_not called, "dry_run must not deliver"
  end

  test "post_release_notes is non-fatal when the webhook is missing" do
    rel = shipped_release
    raiser = ->(content:) { raise ReleaseNotes::DiscordClient::MissingWebhook, "no webhook" }
    ReleaseNotes::DiscordClient.stub(:deliver, raiser) do
      result = Release::Conductor.post_release_notes(release: rel)
      assert_not result[:delivered]
      assert result[:message].present?, "still returns the message even if delivery fails"
    end
  end

  test "post_release_notes survives any delivery error (defense-in-depth)" do
    rel = shipped_release
    # Even a raw transport error (the gap Avi caught) must not fail a completed ship.
    raiser = ->(content:) { raise Net::OpenTimeout, "boom" }
    ReleaseNotes::DiscordClient.stub(:deliver, raiser) do
      result = Release::Conductor.post_release_notes(release: rel)
      assert_not result[:delivered]
      assert result[:message].present?
    end
  end
end
