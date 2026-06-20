require "test_helper"

class ReleaseTest < ActiveSupport::TestCase
  def reviewed_task(title = "Reviewable")
    Task.create!(title: title, stage: "reviewed")
  end

  test "open! creates an assembling release with a generated slug" do
    rel = Release.open!
    assert_equal "assembling", rel.state
    assert rel.slug.start_with?("rel-"), rel.slug
    assert rel.active?
  end

  test "only one active release at a time (singleton)" do
    Release.open!
    assert_raises(ActiveRecord::RecordInvalid) { Release.open! }
  end

  test "a shipped release frees the singleton for a new one" do
    Release.open!.ship!
    assert_nothing_raised { Release.open! }
  end

  test "an abandoned release frees the singleton too" do
    Release.open!.abandon!
    assert_nothing_raised { Release.open! }
  end

  test "Release.current returns the active release" do
    rel = Release.open!
    assert_equal rel, Release.current
    rel.ship!
    assert_nil Release.current
  end

  test "add attaches a reviewed task and marks it assembled" do
    rel = Release.open!
    task = reviewed_task
    rel.add(task)
    assert_equal rel.slug, task.reload.release_slug
    assert_equal "assembled", task.stage
  end

  test "add only works while assembling" do
    rel = Release.open!
    rel.assemble!
    assert_raises(ArgumentError) { rel.add(reviewed_task) }
  end

  test "assemble! marks the release assembled and stamps the time" do
    rel = Release.open!
    rel.assemble!
    assert_equal "assembled", rel.state
    assert_not_nil rel.assembled_at
  end

  test "ship! flips members to shipped, records who, stamps shipped_at" do
    rel = Release.open!
    task = reviewed_task
    rel.add(task)
    rel.assemble!

    rel.ship!(by: "alex")

    assert_equal "shipped", rel.reload.state
    assert_equal "alex", rel.confirmed_by
    assert_not_nil rel.shipped_at
    assert_not_nil rel.confirmed_at
    assert_equal "shipped", task.reload.stage
    assert_not_nil task.completed_at # Task#ship! callback ran (not update_all)
  end

  test "abandon! returns members to reviewed and clears the release link" do
    rel = Release.open!
    task = reviewed_task
    rel.add(task)

    rel.abandon!

    assert_equal "abandoned", rel.reload.state
    assert_equal "reviewed", task.reload.stage
    assert_nil task.release_slug
  end

  test "state must be one of the known states" do
    assert_not Release.new(state: "bogus").valid?
  end

  test "tasks association reads members by release_slug" do
    rel = Release.open!
    a = reviewed_task("A")
    b = reviewed_task("B")
    rel.add(a)
    rel.add(b)
    assert_equal 2, rel.tasks.count
    assert_equal rel, a.reload.release
  end
end
