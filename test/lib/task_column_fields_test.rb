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

  # ── [unit] dependencies: the first LIST column ──────────────────────────────
  #
  # The module was built for scalars, and `dependencies` is jsonb holding an
  # ARRAY. Every case below fails against the scalar reduction (`to_s.strip`):
  # `[]` inspects to the non-blank string "[]", so an EMPTY list would classify
  # as SET — which is this module's founding defect (a field that cannot say
  # "empty" in words) arriving via a type it had not met.

  def test_unit_an_empty_list_column_is_unset_not_set
    assert_equal :unset, TaskColumnFields.state({ "dependencies" => [] }, "dependencies"),
                 "[] must not classify as SET — to_s on an empty array is the non-blank string \"[]\""
    assert_equal :unset, TaskColumnFields.state({ "dependencies" => ["", "  "] }, "dependencies"),
                 "a list of blanks declares nothing"
    assert_equal :set, TaskColumnFields.state({ "dependencies" => ["adopt-modal-primitive"] }, "dependencies")
  end

  def test_unit_a_missing_list_column_stays_distinct_from_an_empty_one
    assert_equal :unreported, TaskColumnFields.state({ "slug" => "t" }, "dependencies")
    refute_equal TaskColumnFields.read({ "slug" => "t" }, "dependencies"),
                 TaskColumnFields.read({ "dependencies" => [] }, "dependencies"),
                 "an unreported list and an empty one must not render alike"
  end

  # The rendering has to ROUND-TRIP into the flag that wrote it. Ruby's inspect
  # form (`["a", "b"]`) is not `--depends-on a --depends-on b`, so an operator
  # reading it back could not copy it forward.
  def test_unit_a_populated_list_renders_as_plain_slugs_not_ruby_inspect
    read = TaskColumnFields.read({ "dependencies" => %w[publish-modal-block adopt-modal-primitive] },
                                 "dependencies")
    assert_equal "publish-modal-block, adopt-modal-primitive", read
    refute_includes read, "[", "the inspect form does not round-trip into --depends-on"
    refute_includes read, "\""
  end

  def test_unit_an_empty_list_reads_as_a_definite_negative_in_words
    read = TaskColumnFields.read({ "dependencies" => [] }, "dependencies")
    assert_equal "no declared dependencies", read
    refute_equal "-", read
    refute_includes read, "[]", "\"[]\" is the scalar reduction leaking through"
  end

  # ORDER IS THE DECLARATION. The column feeds a topological sort, so rendering
  # a sorted or otherwise re-ordered copy would show the operator a sequence they
  # did not write.
  def test_unit_list_rendering_preserves_the_declared_order
    assert_equal "zeta-task, alpha-task",
                 TaskColumnFields.read({ "dependencies" => %w[zeta-task alpha-task] }, "dependencies")
  end

  # The CLI resolves these names from the COLUMN and never from metadata.devops;
  # a name missing here silently falls back to the devops-first lookup in
  # `bin/task field`, which is the two-universe bug this list exists to close.
  def test_unit_dependencies_is_registered_as_a_column_backed_name
    assert_includes TaskColumnFields::COLUMN_NAMES, "dependencies"
    assert_includes TaskColumnFields::UNSET_READS.keys, "dependencies",
                    "without an UNSET_READS entry the empty case falls back to the generic \"none\""
  end

  # A scalar column must not regress while the list support is added.
  def test_unit_scalar_columns_are_unchanged_by_list_support
    assert_equal :set, TaskColumnFields.state({ "merged" => "accepted" }, "merged")
    assert_equal "accepted", TaskColumnFields.read({ "merged" => "accepted" }, "merged")
    assert_equal "not merged", TaskColumnFields.read({ "merged" => "" }, "merged")
    assert_equal TaskColumnFields::UNREPORTED_READS, TaskColumnFields.read({}, "merged")
  end
end
