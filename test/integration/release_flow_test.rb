require "test_helper"

# Integration: the Release lifecycle across multiple Task records and the DB —
# assemble reviewed tasks, ship the candidate, members flip; abandon frees them.
class ReleaseFlowTest < ActionDispatch::IntegrationTest
  def app_reviewed(title, repo: "mcritchie-studio")
    Task.create!(title: title, stage: "reviewed",
                 metadata: { "devops" => { "shape" => "backend", "repositories" => [repo] } })
  end

  test "persistent-release flow: adopt two merged tasks → prepare assembles → ship flips shipped" do
    a = app_reviewed("Release flow A")
    b = app_reviewed("Release flow B")

    # PR for A merged INTO the persistent `release` branch → adopt! records
    # membership + flips the task reviewed→assembled (the release stays open).
    rel = Release::Conductor.adopt!(a)
    assert_equal "release", rel.branch # the persistent per-repo branch
    assert_equal "assembling", rel.state
    # PR for B merged later → the same active release absorbs it.
    Release::Conductor.adopt!(b)

    assert_equal %w[assembled assembled], [a.reload.stage, b.reload.stage]
    assert_equal [rel.slug, rel.slug], [a.release_slug, b.release_slug]
    assert_equal 2, rel.reload.tasks.count

    # prepare assembles the active release (the QA gate); membership is NOT added
    # here — it already flipped at merge.
    Release::Conductor.prepare!(task_slugs: [])
    assert_equal "assembled", rel.reload.state

    rel.ship!(by: "alex")
    assert_equal "shipped", rel.reload.state
    assert_equal %w[shipped shipped], [a.reload.stage, b.reload.stage]
  end

  test "a mixed gem + app release plans the gem first (producer-first) with its version" do
    gem = Task.create!(title: "engine 0.8 gem release", stage: "reviewed",
                       metadata: { "devops" => { "shape" => "library", "repositories" => ["studio-engine"] } })
    app = Task.create!(title: "consume engine 0.8", stage: "reviewed", dependencies: [gem.slug],
                       metadata: { "devops" => {
                         "shape" => "backend", "repositories" => ["turf-monster"],
                         "branch" => "feat/consume-engine",
                         "pr_url" => "https://github.com/amcritchie/turf-monster/pull/200"
                       } })

    # Pass the consumer first — ordering must still come out producer-first.
    rel = Release::Conductor.prepare!(task_slugs: [app.slug, gem.slug], slug: "rel-mixed-flow")

    assert_equal "assembled", rel.state
    assert_equal 2, rel.tasks.count
    assert_equal %w[assembled assembled], [gem.reload.stage, app.reload.stage]

    plan = nil
    Release::Repos.stub(:gem_version, ->(repo) { repo == "studio-engine" ? "0.8.0" : nil }) do
      plan = Release::Conductor.member_plan(rel)
    end

    # Producer-first: the gem rides first; the consumer (which declares the gem
    # in its dependencies) sorts after it.
    assert_equal [gem.slug, app.slug], plan.map { |m| m[:slug] }
    gem_member, app_member = plan

    assert_equal "gem", gem_member[:kind]
    assert_equal "studio-engine", gem_member[:repo]
    assert_equal "0.8.0", gem_member[:version]
    assert_nil gem_member[:branch], "a gem member has no app branch to merge"

    assert_equal "app", app_member[:kind]
    assert_equal "turf-monster", app_member[:repo]
    assert_equal "feat/consume-engine", app_member[:branch]
    assert_nil app_member[:version]
  end

  test "a gem member is represented so prepare can freeze it: repo_plan tags it gem + record_qa_shas round-trips its SHA" do
    gem = Task.create!(title: "engine 0.9 gem release", stage: "reviewed",
                       metadata: { "devops" => { "shape" => "library", "repositories" => ["studio-engine"] } })
    app = Task.create!(title: "consume engine 0.9", stage: "reviewed", dependencies: [gem.slug],
                       metadata: { "devops" => {
                         "shape" => "backend", "repositories" => ["mcritchie-studio"],
                         "branch" => "feat/consume-engine-09",
                         "pr_url" => "https://github.com/amcritchie/mcritchie-studio/pull/300"
                       } })

    rel = Release::Conductor.prepare!(task_slugs: [gem.slug, app.slug], slug: "rel-gem-freeze")
    assert_equal "assembled", rel.state

    # The gem repo is represented in the deploy plan as kind :gem, producer-first —
    # this is the group bin/release's prepare loop reaches to freeze qa_shas[gem].
    plan = Release::Conductor.repo_plan(rel)
    assert_equal %w[studio-engine mcritchie-studio], plan.map { |g| g[:repo] }
    gem_group = plan.find { |g| g[:repo] == "studio-engine" }
    assert_equal :gem, gem_group[:kind]
    assert_equal [gem.slug], gem_group[:members].map { |m| m[:slug] }
    assert_equal "gem", Release::Conductor.member_plan(rel).first[:kind]

    # The gem's frozen SHA round-trips onto the release exactly like an app's, so
    # ship's frozen_sha_for reads the QA-frozen commit, not origin/release HEAD.
    Release::Conductor.record_qa_shas(release: rel,
                                      shas: { "studio-engine" => "gemsha1", "mcritchie-studio" => "appsha2" })
    qa_shas = rel.reload.metadata["qa_shas"]
    assert_equal "gemsha1", qa_shas["studio-engine"]
    assert_equal "gemsha1", Release::ShipSequence.frozen_sha(qa_shas, "studio-engine"),
                 "ship selects the frozen gem SHA — no live origin/release fallback"
  end

  test "abandon frees the member tasks and the active-release singleton" do
    a = Task.create!(title: "Abandon flow A", stage: "reviewed")
    rel = Release.open!
    rel.add(a)

    rel.abandon!

    assert_equal "reviewed", a.reload.stage
    assert_nil a.release_slug
    assert_nothing_raised { Release.open! } # singleton freed for a fresh candidate
  end
end
