# frozen_string_literal: true

require "test_helper"

# `tasks.epic_slug` — the one optional field the board carries for an epic
# (docs/agents/system/devops-v3-design.md §3). There is no Epic model: the plan
# lives with the focus session, and this column is only the handle the card's
# epic chip prints and `/tasks?epic=<slug>` filters on.
#
# These cases pin the WRITE side of that contract: the canonical form every
# writer lands in, the refusal that keeps an unprintable handle out, the clear
# spelling, and the column-not-devops rule that stops a shadow store from
# diverging the way release_slug's once did.
#
# Its own file, like task_dependencies_test.rb: the suite's hotspot ceilings
# freeze task_test.rb as an APPEND hotspot, so a cohesive new block goes
# somewhere with its own bottom. (The registry's path is deliberately not spelled
# here — the fast-cert mapper follows a spelled config path, and this file would
# otherwise join that config's mapped set; see test/lib/fast_cert_subject_test.rb.)
class TaskEpicSlugTest < ActiveSupport::TestCase
  test "[unit] epic_slug is normalized to a lowercase, stripped slug" do
    task = Task.create!(title: "Epic Normalized Task", epic_slug: "  DevOps-V3 ")

    assert_equal "devops-v3", task.reload.epic_slug
  end

  test "[unit] a blank epic_slug normalizes to nil, never an empty string" do
    task = Task.create!(title: "Epic Blank Task", epic_slug: "   ")

    assert_nil task.reload.epic_slug
  end

  # `"none"` is the CLI's clear spelling (`--epic none`), honoured at the model so
  # an API writer can clear the column without reaching for JSON null.
  test "[unit] the clear token none empties a set epic_slug" do
    task = Task.create!(title: "Epic Clear Task", epic_slug: "devops-v3")
    task.update!(epic_slug: "NONE")

    assert_nil task.reload.epic_slug
  end

  test "[unit] nil clears a set epic_slug" do
    task = Task.create!(title: "Epic Nil Clear Task", epic_slug: "devops-v3")
    task.update!(epic_slug: nil)

    assert_nil task.reload.epic_slug
  end

  # A handle the chip cannot print and the filter cannot match is refused at the
  # door, quoting the rule, rather than stored in a shape `?epic=` never finds.
  test "[unit] an epic_slug that is not a slug is refused" do
    task = Task.new(title: "Epic Malformed Task", epic_slug: "DevOps V3!")

    assert_not task.valid?
    assert_match(/must be a slug/, task.errors[:epic_slug].join)
  end

  test "[unit] a task with no epic stays valid" do
    task = Task.new(title: "Epic Absent Task")

    assert task.valid?, task.errors.full_messages.join(", ")
    assert_nil task.epic_slug
  end

  test "[unit] the epic charset is the task-slug charset" do
    assert_equal Task::DEPENDENCY_SLUG, Task::EPIC_SLUG,
                 "the chip prints it beside the task slug; the two must read by one rule"
  end

  # THE COLUMN-NOT-DEVOPS RULE. A devops write to the name is refused loudly and
  # names the flag that does work — the release_slug incident was a same-named
  # devops key diverging from the column, with the visible one inert.
  test "[unit] a devops epic_slug write is refused and names --epic" do
    error = assert_raises(ArgumentError) do
      Task.normalize_devops_metadata({ "kind" => "feature", "epic_slug" => "devops-v3" })
    end

    assert_match(/devops\.epic_slug is not writable/, error.message)
    assert_match(/tasks\.epic_slug column/, error.message)
    assert_match(/--epic/, error.message, "the refusal must name the command that DOES work")
  end

  test "[unit] a stored devops epic_slug shadow is shed on save" do
    task = Task.create!(title: "Epic Shadow Task", epic_slug: "devops-v3")
    task.update_columns(metadata: { "devops" => { "kind" => "feature", "epic_slug" => "stale-shadow" } })

    task.reload.update!(description: "any unrelated save")

    assert_nil task.reload.metadata.dig("devops", "epic_slug"), "the shadow must not survive a save"
    assert_equal "devops-v3", task.epic_slug, "the column is the only store"
  end

  # The read side both boards and the API index share.
  test "[unit] for_epic matches through the same normalization the write used" do
    member = Task.create!(title: "Epic Member Task", epic_slug: "devops-v3")
    Task.create!(title: "Epic Other Task", epic_slug: "other-epic")
    Task.create!(title: "Epic None Task")

    assert_equal [member.slug], Task.for_epic(" DevOps-V3 ").pluck(:slug)
  end

  # An epic link that resolved to "everything" would read as a working filter.
  test "[unit] for_epic with a blank or clear value is an empty scope, not the whole board" do
    Task.create!(title: "Epic Member Task", epic_slug: "devops-v3")

    assert_empty Task.for_epic("")
    assert_empty Task.for_epic(nil)
    assert_empty Task.for_epic("none")
  end

  test "[unit] epic_slug rides the task JSON as a top-level key" do
    task = Task.create!(title: "Epic Json Task", epic_slug: "devops-v3")

    assert_equal "devops-v3", task.as_json["epic_slug"]
  end
end
