# frozen_string_literal: true

require "test_helper"

# The WRITER half of `tasks.dependencies` — Release::Ordering's explicit
# task-to-task release edge.
#
# The column fed `Release::Ordering.producer_first` for months with NO writer
# outside tests calling `Task.create!` directly, while four documents told agents
# to declare it. These cases pin the writer's half of that contract: the SHAPE
# the reader resolves against, and the refusals that keep a declaration from
# being stored in a form the reader silently ignores.
#
# WHY ITS OWN FILE: they need no harness beyond `Task.create!`, and
# config/test_health.yml freezes task_test.rb as an APPEND hotspot precisely so a
# cohesive new block goes somewhere with its own bottom.
class TaskDependenciesTest < ActiveSupport::TestCase
  def dependency_target(title = "Publish Modal Block")
    Task.create!(title: title)
  end

  test "[unit] dependencies normalize to a flat list of slug strings" do
    target = dependency_target
    other = dependency_target("Adopt Modal Primitive")
    task = Task.create!(title: "Ordered Consumer Task",
                        dependencies: [target.slug, "  ", other.slug, target.slug, nil])

    assert_equal [target.slug, other.slug], task.reload.dependencies,
                 "blanks and duplicates are dropped; the operator's ORDER is preserved"
  end

  # Array() is the reader's coercion, and it is generous in the wrong direction:
  # a bare String becomes a working one-element list, so the wrong shape SURVIVES
  # and teaches the writer the wrong lesson. Normalize at the door instead.
  test "[unit] a bare string dependency is coerced to a one-element list" do
    target = dependency_target
    task = Task.create!(title: "String Shape Task", dependencies: target.slug)

    assert_equal [target.slug], task.reload.dependencies
  end

  # The shape that fails SILENTLY at the reader: Array({"a" => 1}) is [["a", 1]],
  # so every "dependency" is a two-element array by_slug can never match and the
  # edge never fires.
  test "[unit] a hash dependency is flattened to its values, not to pairs" do
    target = dependency_target
    task = Task.create!(title: "Hash Shape Task", dependencies: { "first" => target.slug })

    assert_equal [target.slug], task.reload.dependencies
    assert(task.dependencies.all?(String), "a pair would be invisible to Release::Ordering's by_slug lookup")
  end

  test "[unit] a nil dependencies value normalizes to an empty list" do
    task = Task.create!(title: "Nil Shape Task", dependencies: nil)

    assert_equal [], task.reload.dependencies
  end

  # THE CENTRAL REFUSAL. producer_first skips a dependency it cannot resolve on
  # purpose, so an unknown slug is indistinguishable from no dependency at all —
  # forever, with no error anywhere and a release that ships in the wrong order
  # as the only evidence.
  test "[unit] a dependency naming no task is refused" do
    task = Task.new(title: "Typo Dependency Task", dependencies: ["adopt-modal-primitve"])

    assert_not task.valid?
    assert_match(/name no task on this board/, task.errors[:dependencies].join)
    assert_match(/adopt-modal-primitve/, task.errors[:dependencies].join,
                 "the refusal must quote the slug that missed, or the operator cannot fix it")
  end

  test "[unit] a malformed dependency is refused before the existence lookup" do
    task = Task.new(title: "Malformed Dependency Task", dependencies: ["Adopt Modal Primitive"])

    assert_not task.valid?
    assert_match(/must be task slugs/, task.errors[:dependencies].join)
  end

  # A self-dependency can never be satisfied, so producer_first falls through to
  # its `index ||= 0` cycle-breaker and takes the head anyway: the declaration is
  # discarded by a safety valve rather than honored.
  test "[unit] a task cannot depend on itself" do
    task = Task.create!(title: "Self Dependency Task")
    task.dependencies = [task.slug]

    assert_not task.valid?
    assert_match(/own slug/, task.errors[:dependencies].join)
  end

  test "[unit] a dependency naming a real task is accepted" do
    target = dependency_target
    task = Task.create!(title: "Valid Dependency Task", dependencies: [target.slug])

    assert_equal [target.slug], task.reload.dependencies
  end

  # Gated on change, exactly like the title/acceptance validations: a task saved
  # for any OTHER reason must not become unsaveable because a dependency it
  # declared last month has since been deleted. Writing the field is what has to
  # be right.
  test "[unit] an unrelated save survives a dependency that has since vanished" do
    target = dependency_target
    task = Task.create!(title: "Grandfathered Dependency Task", dependencies: [target.slug])
    target.destroy!

    task.reload
    task.title = "Grandfathered Dependency Renamed"

    assert task.valid?, "an untouched dependencies list must not block an unrelated write"
    assert task.save
  end

  # The other half of DEVOPS_COLUMN_KEYS: the normalizer refuses the write (pinned
  # by the spread test above) and this callback sheds anything a pre-wiring write
  # already parked in the shadow store. Without it LOCATOR's "metadata.devops.<name>
  # is ALWAYS null" would be an aspiration, not a guarantee.
  test "[unit] a stored devops dependencies shadow is shed on save" do
    task = Task.create!(title: "Shadow Dependencies Task")
    task.update_column(:metadata, { "devops" => { "kind" => "chore", "dependencies" => ["never-read"] } })

    task.reload.update!(title: "Shadow Dependencies Renamed")

    assert_nil task.reload.devops["dependencies"],
               "the shadow store must not survive, or the two universes reopen"
    assert_equal "chore", task.devops["kind"], "shedding the shadow must not disturb its neighbours"
  end

  # [integration] THE PRODUCER MEETS THE CONSUMER. Everything above tests the
  # writer in isolation; this asserts the value a supported write stores is the
  # value Release::Ordering actually reorders on. A writer and a reader that
  # merely both exist is what this task was filed to fix.
  test "[integration] a dependency written through the model reorders producer_first" do
    first = Task.create!(title: "Publish Ordering Producer", position: 2)
    second = Task.create!(title: "Adopt Ordering Consumer", position: 1)

    # position alone puts `second` first — the base order the sort falls back to.
    assert_equal [second.slug, first.slug],
                 Release::Ordering.producer_first([first, second]).map(&:slug)

    second.update!(dependencies: [first.slug])

    assert_equal [first.slug, second.slug],
                 Release::Ordering.producer_first([first, second.reload]).map(&:slug),
                 "the declared edge must beat the position fallback"
  end

  # The tolerance producer_first documents, pinned so the refusal above is not
  # mistaken for "every dependency must be in the release".
  test "[integration] a dependency outside the release does not hold a member back" do
    outsider = Task.create!(title: "Outside Release Task")
    member = Task.create!(title: "Inside Release Task", dependencies: [outsider.slug])

    assert_equal [member.slug], Release::Ordering.producer_first([member]).map(&:slug),
                 "an unorderable dependency must not stall the pass"
  end
end
