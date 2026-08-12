# frozen_string_literal: true

# Tests for bin/lib/task_column_fields.rb — the three-state rendering of the
# task fields that live as TOP-LEVEL Task COLUMNS (`merged`, `release_slug`)
# rather than in `metadata["devops"]` like their neighbours.
#
# The property under test is NOT "merged is printed". It is that the three
# states stay DISTINGUISHABLE, because the defect this module exists for was an
# agent reading "no output" as "the write dropped":
#
#   SET        the value
#   UNSET      a definite negative in words — never a bare "-"
#   UNREPORTED the payload carries no such key, so the tool cannot say
#
# UNSET and UNREPORTED collapsing back into one rendering is the regression.
#
#   ruby -Itest test/lib/task_column_fields_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"

require File.expand_path("../../bin/lib/task_column_fields", __dir__)

class TaskColumnFieldsTest < Minitest::Test
  # ── [unit] state: key-presence is checked before the value ──────────────────

  def test_unit_state_separates_a_missing_key_from_a_nil_value
    assert_equal :unreported, TaskColumnFields.state({ "slug" => "t" }, "merged"),
                 "a payload with no merged key means the tool cannot say"
    assert_equal :unset, TaskColumnFields.state({ "merged" => nil }, "merged"),
                 "a present-but-nil column is a definite 'not merged'"
    assert_equal :unset, TaskColumnFields.state({ "merged" => "" }, "merged")
    assert_equal :unset, TaskColumnFields.state({ "merged" => "   " }, "merged")
    assert_equal :set, TaskColumnFields.state({ "merged" => "accepted" }, "merged")
  end

  def test_unit_state_of_a_non_hash_record_is_unreported
    assert_equal :unreported, TaskColumnFields.state(nil, "merged")
    assert_equal :unreported, TaskColumnFields.state("accepted", "merged")
  end

  # ── [unit] read: the three renderings, and that they never coincide ─────────

  def test_unit_read_returns_the_stamped_value
    assert_equal "accepted", TaskColumnFields.read({ "merged" => "accepted" }, "merged")
    assert_equal "main", TaskColumnFields.read({ "merged" => "main" }, "merged")
  end

  def test_unit_read_states_the_empty_case_in_words_never_as_a_dash
    unset = TaskColumnFields.read({ "merged" => nil }, "merged")
    assert_equal "not merged", unset
    refute_equal "-", unset, "a bare dash is the glyph that read as 'nothing to tell you'"
  end

  def test_unit_read_marks_a_missing_key_as_unreported
    assert_equal TaskColumnFields::UNREPORTED_READS, TaskColumnFields.read({}, "merged")
  end

  # THE REGRESSION GUARD. Both of these render "the value is not there" — and the
  # entire cost of the original defect was an agent unable to tell WHICH one it
  # was looking at. If a future edit makes them print the same string, the module
  # has stopped doing its job even though every other assertion still passes.
  def test_unit_unset_and_unreported_never_render_alike
    %w[merged release_slug].each do |key|
      unset = TaskColumnFields.read({ key => "" }, key)
      unreported = TaskColumnFields.read({}, key)
      refute_equal unset, unreported,
                   "#{key}: an empty column must not read the same as an unreported one"
      refute_empty unset, "#{key}: the empty case must still say something"
    end
  end

  def test_unit_release_slug_gets_its_own_empty_wording
    assert_equal "not on a release", TaskColumnFields.read({ "release_slug" => nil }, "release_slug")
    assert_equal "rel-2026-08-11-hub",
                 TaskColumnFields.read({ "release_slug" => "rel-2026-08-11-hub" }, "release_slug")
  end

  # A column with no bespoke wording still gets a WORD, not a dash — so adding a
  # field to the printed set can never reintroduce the ambiguous glyph.
  def test_unit_an_unlisted_column_falls_back_to_a_word
    assert_equal "none", TaskColumnFields.read({ "po_size" => nil }, "po_size")
  end

  # ── [unit] pair + locator ───────────────────────────────────────────────────

  def test_unit_pair_labels_the_value_with_its_field_name
    assert_equal "merged: accepted", TaskColumnFields.pair({ "merged" => "accepted" }, "merged")
    assert_equal "merged: not merged", TaskColumnFields.pair({ "merged" => nil }, "merged")
  end

  # The locator is the sentence that names the lookup error behind all three
  # recorded incidents. It has to say both halves: where the field IS, and that
  # the devops path an agent would reach for is empty.
  def test_unit_locator_names_the_column_and_the_empty_devops_path
    assert_match(/top-level/i, TaskColumnFields::LOCATOR)
    assert_match(/metadata\.devops/, TaskColumnFields::LOCATOR)
  end
end
