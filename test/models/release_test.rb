require "test_helper"

class ReleaseTest < ActiveSupport::TestCase
  def reviewed_task(label = "default")
    Task.create!(title: "reviewable #{label} demo task", stage: "reviewed")
  end

  test "open! creates an assembling release with a generated slug" do
    rel = Release.open!
    assert_equal "assembling", rel.state
    assert rel.slug.start_with?("rel-"), rel.slug
    assert rel.active?
  end

  test "open! defaults the integration branch to the persistent `release`" do
    assert_equal "release", Release::BRANCH
    assert_equal "release", Release.open!.branch
  end

  test "current_or_open! returns the active release, else opens one" do
    opened = Release.current_or_open!
    assert_equal "assembling", opened.state
    assert_equal opened, Release.current_or_open!, "returns the SAME active release, doesn't open a second"
    assert_equal 1, Release.count
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

  test "add from an assembled RC auto-reopens, then adds (a late merge re-QAs)" do
    rel = Release.open!
    rel.assemble!
    assert_equal "assembled", rel.state

    rel.add(reviewed_task)

    assert_equal "assembling", rel.reload.state, "a late merge reopens the candidate"
    assert_equal 1, rel.tasks.count
  end

  test "add still refuses from a terminal release" do
    rel = Release.open!
    rel.ship!
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

  # --- reopen! (additive prepare: absorb new work into an assembled RC) ---

  test "reopen! pulls an assembled release back to assembling" do
    rel = Release.open!
    rel.assemble!
    rel.reopen!
    assert_equal "assembling", rel.reload.state
  end

  test "reopen! only works from assembled" do
    rel = Release.open! # assembling
    assert_raises(ArgumentError) { rel.reopen! }
    rel.assemble!
    rel.ship!
    assert_raises(ArgumentError) { rel.reopen! } # terminal
  end

  test "reopen! lets a new reviewed task join an already-assembled RC" do
    rel = Release.open!
    rel.add(reviewed_task("first"))
    rel.assemble!

    rel.reopen!
    rel.add(reviewed_task("second"))
    rel.assemble!

    assert_equal 2, rel.tasks.count
    assert_equal "assembled", rel.reload.state
  end

  # --- transition guards (a terminal release must stay terminal) ---

  test "a terminal release cannot be revived" do
    rel = Release.open!
    rel.ship!
    assert_raises(ArgumentError) { rel.assemble! }
    assert_raises(ArgumentError) { rel.ship! }
    assert_raises(ArgumentError) { rel.abandon! }
  end

  test "assemble! only transitions from assembling" do
    rel = Release.open!
    rel.assemble!
    assert_raises(ArgumentError) { rel.assemble! } # already assembled
  end

  test "add rejects a task that is not reviewed" do
    rel = Release.open!
    designed = Task.create!(title: "Not reviewed yet") # stage: designed
    assert_raises(ArgumentError) { rel.add(designed) }
  end
end
