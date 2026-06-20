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
