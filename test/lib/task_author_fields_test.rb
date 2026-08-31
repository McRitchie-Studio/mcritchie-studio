# frozen_string_literal: true

# Tests for bin/lib/task_author_fields.rb — the rendering that separates WHO A
# TASK IS ASSIGNED TO from WHO ACTUALLY BUILT IT.
#
# The property under test is NOT "built_by is printed". It is that the two facts
# stay TELLABLE APART, because the defect this module exists for was an agent
# reading the assignee under a label it took for the author:
#
#   `bin/task show <slug>` printed `agent: <agent_slug>`. The field review reads
#   is `metadata.devops.built_by`, and `bin/task move <slug> building --actor
#   <soul>` stamps that WITHOUT setting agent_slug — so three of four tasks
#   measured on 2026-08-30 printed `agent: -` while correctly stamped, and two
#   agents reported the blank as a review-integrity incident.
#
# So plumbing built_by to the same `agent:` label would have been the same defect
# wearing new plumbing. The regressions these cases guard against are therefore
# (a) the author set vanishing from the summary again, and (b) the two facts
# collapsing back into one name or one glyph.
#
#   ruby -Itest test/lib/task_author_fields_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"

require File.expand_path("../../bin/lib/task_author_fields", __dir__)

class TaskAuthorFieldsTest < Minitest::Test
  # A fetched API record (`data`), shaped exactly as the board serves it: devops
  # under metadata, agent_slug as a TOP-LEVEL column. Getting that nesting wrong
  # is the whole bug, so the fixture spells it out rather than hiding it behind
  # a builder that could quietly agree with the code.
  def record(agent_slug: nil, **devops)
    { "slug" => "demo-task", "stage" => "building", "agent_slug" => agent_slug,
      "metadata" => { "devops" => devops.transform_keys(&:to_s) } }
  end

  # ── [unit] THE ACCEPTANCE CASE: an actor-stamped task shows its builder ─────

  # The exact shape of three of the four measured tasks: `--actor <soul>` stamped
  # the author, nothing assigned the task. The old line rendered `-` here.
  def test_unit_an_actor_stamped_task_with_no_assignee_shows_the_builder
    task = record(built_by: "avi", builders: ["avi"])

    assert_equal "avi", TaskAuthorFields.read(task)
    assert_equal "builders: avi", TaskAuthorFields.pair(task)
  end

  # The pre-accumulator record: `built_by` stamped, `builders` never written
  # (the key did not exist yet). The union must still name the author, or every
  # task older than the accumulator reads as unstamped.
  def test_unit_a_task_stamped_before_the_builders_accumulator_still_names_its_author
    assert_equal "steffon", TaskAuthorFields.read(record(built_by: "steffon"))
  end

  # The handoff: a session limit kills the claimer and a second soul finishes the
  # work, so `builders` accumulates past `built_by`. Both are authors and both
  # must show — naming only the first is what seated an author on his own PR.
  def test_unit_every_soul_in_the_author_set_is_named
    task = record(built_by: "shannon", builders: %w[shannon alex])

    assert_equal "shannon, alex", TaskAuthorFields.read(task)
  end

  # Order matches ReviewerSelector#builders (built_by leads), so the display and
  # the selector cannot describe one task two ways.
  def test_unit_built_by_leads_the_set_and_duplicates_collapse
    task = record(built_by: "alex", builders: %w[shannon alex])

    assert_equal "alex, shannon", TaskAuthorFields.read(task)
  end

  # ── [unit] THE TWO EMPTIES, which must never read alike ─────────────────────

  # "Nobody is assigned" is ordinary. "Nobody is recorded as having built it"
  # blocks review. A shared "-" said both, which is precisely how a stamped task
  # got reported as unstamped.
  def test_unit_unassigned_and_unstamped_are_different_renderings
    blank = record

    assert_equal "unassigned", TaskAuthorFields.assignee_read(blank)
    assert_equal "NOT STAMPED", TaskAuthorFields.read(blank)
    refute_equal TaskAuthorFields.assignee_read(blank), TaskAuthorFields.read(blank),
                 "the assignee gap and the author gap are different facts"
  end

  # Neither empty may render as the glyph that caused the incident.
  def test_unit_neither_empty_state_renders_as_a_bare_dash
    blank = record

    refute_equal "-", TaskAuthorFields.read(blank)
    refute_equal "-", TaskAuthorFields.assignee_read(blank)
  end

  # An assignee is NOT an author. A task assigned to jasper and built by carl
  # must say so — this is the disagreement the old single line could not express
  # at all, and asserting on the pair (not a substring) is what pins it: "jasper"
  # appearing SOMEWHERE in the output is exactly the weak check that would pass
  # on the defect.
  def test_unit_the_assignee_is_never_folded_into_the_author_set
    task = record(agent_slug: "jasper", built_by: "carl", builders: ["carl"])

    assert_equal "assignee: jasper", TaskAuthorFields.assignee_pair(task)
    assert_equal "builders: carl", TaskAuthorFields.pair(task)
    refute_includes TaskAuthorFields.read(task), "jasper",
                    "an assignee who built nothing must not be reported as an author"
  end

  # And the reverse: a stamped author must not leak into the assignee reading.
  def test_unit_a_stamped_author_does_not_become_an_assignee
    task = record(built_by: "carl", builders: ["carl"])

    assert_equal "unassigned", TaskAuthorFields.assignee_read(task),
                 "built_by says who worked it, not who it is assigned to"
  end

  # ── [unit] THE INCOMPLETE SET ───────────────────────────────────────────────

  # `builders_unattributed` means a session worked this task while naming no
  # soul, so the names on record are a SUBSET. Rendering them as if they were the
  # whole set is the failure that fails CONFIDENTLY rather than closed.
  def test_unit_an_unattributed_author_marks_the_set_incomplete
    task = record(built_by: "shannon", builders: ["shannon"],
                  builders_unattributed: "02a41c7d-4b9e-84c2-af9c-041f22ac02c7")

    assert_equal "shannon +1 UNNAMED", TaskAuthorFields.read(task)
    refute_equal TaskAuthorFields.read(record(built_by: "shannon", builders: ["shannon"])),
                 TaskAuthorFields.read(task),
                 "a complete set and an incomplete one must not render alike"
  end

  # A blank flag is not a flag. The board serves the key absent on most tasks and
  # "" on some; both mean nothing is missing.
  def test_unit_a_blank_unattributed_flag_does_not_mark_the_set_incomplete
    task = record(built_by: "carl", builders: ["carl"], builders_unattributed: "  ")

    assert_nil TaskAuthorFields.unattributed(task)
    assert_equal "carl", TaskAuthorFields.read(task)
  end

  # ── [unit] VALUES THAT ARE NOT SOULS ────────────────────────────────────────

  # A bare `bin/task move <slug> building` records the SESSION as the event
  # actor. A display that counted it would report an author on exactly the task
  # where reviewer-select reports none — the same class of confident-wrong
  # answer, aimed the other way.
  def test_unit_a_session_id_on_the_record_is_not_a_named_author
    task = record(built_by: "02a41c7d-4b9e-84c2-af9c-041f22ac02c7")

    assert_empty TaskAuthorFields.names(task)
    assert_includes TaskAuthorFields.read(task), "NOT STAMPED"
  end

  # But it is not INVISIBLE either: it is the tell that a claim ran without
  # `--actor`, and a bare "NOT STAMPED" would send the reader hunting for a write
  # that did happen. The value is shown, labelled as unusable.
  def test_unit_a_session_id_is_still_shown_so_the_reader_can_see_the_cause
    session = "02a41c7d-4b9e-84c2-af9c-041f22ac02c7"

    assert_includes TaskAuthorFields.read(record(built_by: session)), session
    assert_includes TaskAuthorFields.read(record(built_by: session)), "not a soul handle"
  end

  # An operator email reaches the record the same way (a board move stamps
  # current_user.email). It is not an author either.
  def test_unit_an_operator_email_is_not_a_named_author
    task = record(built_by: "alex@mcritchie.studio")

    assert_empty TaskAuthorFields.names(task)
  end

  # ── [unit] the --verbose source line ────────────────────────────────────────

  # UNCONDITIONAL, and never a bare "-". This is the line an agent verifies a
  # stamp on; a field that disappears when empty reproduces the original
  # ambiguity ("no output" → "the write dropped") one surface over.
  def test_unit_the_source_line_names_all_three_fields_even_when_empty
    line = TaskAuthorFields.source_line(record)

    assert_includes line, "built_by: NOT STAMPED"
    assert_includes line, "builders: NOT STAMPED"
    assert_includes line, "unattributed: none"
  end

  def test_unit_the_source_line_reports_each_field_from_its_own_key
    line = TaskAuthorFields.source_line(
      record(built_by: "alex", builders: %w[shannon alex], builders_unattributed: "sess-9")
    )

    assert_includes line, "built_by: alex"
    assert_includes line, "builders: shannon, alex"
    assert_includes line, "unattributed: sess-9"
  end

  # The locator is the sentence that would have saved both false alarms — the
  # error was the lookup PATH, not the value. It must name both stores.
  def test_unit_the_locator_names_where_each_fact_lives
    assert_includes TaskAuthorFields::LOCATOR, "metadata.devops.builders"
    assert_includes TaskAuthorFields::LOCATOR, "agent_slug"
  end

  # ── [unit] defensive shapes ─────────────────────────────────────────────────

  # A record fetched from a trimmed endpoint carries no metadata at all. The
  # rendering must degrade to the loud empty, not raise inside a print.
  def test_unit_a_record_without_metadata_reads_as_unstamped
    assert_equal "NOT STAMPED", TaskAuthorFields.read({ "slug" => "demo-task" })
    assert_equal "unassigned", TaskAuthorFields.assignee_read({ "slug" => "demo-task" })
  end
end
