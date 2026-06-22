require "test_helper"

# Integration: the Release lifecycle across multiple Task records and the DB —
# assemble reviewed tasks, ship the candidate, members flip; abandon frees them.
class ReleaseFlowTest < ActionDispatch::IntegrationTest
  test "assemble two reviewed tasks, ship the release, both flip to shipped" do
    a = Task.create!(title: "Release flow A", stage: "reviewed")
    b = Task.create!(title: "Release flow B", stage: "reviewed")

    rel = Release.open!(branch: "release/2026-flow-test")
    rel.add(a)
    rel.add(b)

    assert_equal %w[assembled assembled], [a.reload.stage, b.reload.stage]
    assert_equal [rel.slug, rel.slug], [a.release_slug, b.release_slug]
    assert_equal 2, rel.tasks.count

    rel.assemble!
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
