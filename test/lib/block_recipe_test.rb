# frozen_string_literal: true

require "minitest/autorun"
require "shellwords"
require_relative "../../bin/lib/block_recipe"

# [unit] EVERY RECIPE IN THE TABLE NAMES ITS ACTING SOUL — enumerated from the table
# itself, so a row added next year is covered the moment it exists.
#
# THE DEFECT (/tasks/breaker-remedy-omits-agent). The two-bounce breaker printed two
# copy-pasteable `bin/task block` commands and NEITHER carried `--agent`. A bare block
# does not run as whoever pastes it — `resolved_block_actor` falls through an unset
# session persona to `default_block_actor`, which returns the literal "avi" for
# rework-on-submitted and NIL for every other kind — so the escalation landed a block
# with no actor at all.
#
# WHAT THAT COSTS (corrected 2026-09-08 in bin/lib/block_recipe.rb and
# test/commands/breaker_remedy_names_its_soul_test.rb; this header was the third copy
# and was missed by that sweep). An earlier draft said the unattributed entry joins the
# task's AUTHOR SET and makes `bin/reviewer-select` refuse to pick. It does not.
# `Task#block!` sets `blocked_at`, which `build_claim_save?` rejects and `submit_save?`
# never matches, so `enforce_builder_stamp` writes no author on the block PATCH at all.
# The chain is SECOND-ORDER: the block lands the task on `building`, the statusline
# heartbeat adopts the freed lease with no soul, and THAT stamps
# `builders_unattributed`. Misattributed audit row: real, and worth this file.
# Disarmed no-self-review guard: not this seam.
#
# WHY THIS FILE ENUMERATES RATHER THAN NAMES. The ticket named ONE coordinate,
# bin/task's breaker-ack line. The escalation printed three lines above it was the
# same shape and the worse of the two — it was the one that actually wrote an
# unattributed block — and a test naming only the filed coordinate would have shipped
# green beside it. So the assertion walks `TEMPLATES` and the FLOOR below is what makes
# a green run mean something: if the table is ever emptied or renamed, the loop runs
# zero times and every property here would pass vacuously.
#
# The recipes are also EXECUTED, end to end, in
# test/commands/breaker_remedy_names_its_soul_test.rb — a recipe can carry `--agent`
# and still not land it. This file holds the table's shape; that one holds the write.
#
#   ruby -Itest test/lib/block_recipe_test.rb
class BlockRecipeTest < Minitest::Test
  SLUG = "some-task-slug"
  SOUL = "carl"

  # The escalation and the breaker-ack re-run. A floor, not an equality: a THIRD
  # recipe is welcome here and is covered automatically — it just may not drop the
  # set below what the breaker is known to print.
  MINIMUM_RECIPES = 2

  def test_the_table_is_the_whole_set_and_is_not_empty
    assert_operator BlockRecipe::TEMPLATES.size, :>=, MINIMUM_RECIPES,
                    "the recipe table holds #{BlockRecipe::TEMPLATES.size} row(s) — every property below " \
                    "iterates it, so a collapsed table would pass this file having proved nothing"
    assert_equal BlockRecipe::TEMPLATES.size, BlockRecipe.all(SLUG, agent: SOUL).size,
                 "`all` must build every row — a row it skips is a recipe no guard here sees"
  end

  def test_every_recipe_names_the_soul_it_was_built_for
    each_recipe(agent: SOUL) do |name, recipe|
      argv = Shellwords.split(recipe.gsub(/\\\n\s*/, " "))

      assert_includes argv, "--agent", "#{name} prints no --agent:\n#{recipe}"
      assert_equal SOUL, argv[argv.index("--agent") + 1],
                   "#{name} names the wrong soul — the flag must carry the value it was built with:\n#{recipe}"
    end
  end

  def test_every_recipe_is_the_block_invocation_it_claims_to_be
    each_recipe(agent: SOUL) do |name, recipe|
      argv = Shellwords.split(recipe.gsub(/\\\n\s*/, " "))

      script, subcommand, target = argv.first(3)

      # ABSOLUTE BY CONSTRUCTION (remedy-hints-second-wave). A recipe is pasted, and the
      # bare `bin/task` pastes only from a hub desk — so this asks the DISK rather than
      # comparing text: an absolute path CONTAINS "bin/task", which is exactly why a
      # substring or bare-equality assertion cannot see this defect.
      assert_equal File.expand_path(script), script,
                   "#{name} opens with a NON-ABSOLUTE command — a reviewer on a satellite or gem " \
                   "desk cannot paste it:\n#{recipe}"
      assert File.executable?(script),
             "#{name} opens with #{script.inspect}, which is not an executable on this disk:\n#{recipe}"
      assert_equal "task", File.basename(script), "#{name} does not open as `bin/task`:\n#{recipe}"
      assert_equal ["block", SLUG], [subcommand, target],
                   "#{name} does not open as `bin/task block <slug>`:\n#{recipe}"
      assert_includes argv, "--kind", "#{name} names no block kind:\n#{recipe}"
    end
  end

  # A leaked marker would print `--agent <agent>` — which reads like the visible blank
  # and is not one, because nothing told the reader to fill it in.
  def test_no_recipe_leaks_an_unsubstituted_marker
    each_recipe(agent: SOUL) do |name, recipe|
      refute_includes recipe, "<slug>", "#{name} leaked the slug marker:\n#{recipe}"
      refute_includes recipe, "<agent>", "#{name} leaked the agent marker:\n#{recipe}"
    end
  end

  # ── the unresolvable case ───────────────────────────────────────────────────
  #
  # `resolved_block_actor` returns "" when it can name nobody, and "" is exactly the
  # state in which a pasted block lands unattributed. The recipe must then show a
  # BLANK the reader can see, never a default: a confidently wrong soul is worse than
  # a missing one, because nobody corrects what they cannot notice.

  def test_an_unresolvable_soul_prints_a_visible_blank_in_every_recipe
    ["", "   ", nil].each do |blank|
      each_recipe(agent: blank) do |name, recipe|
        assert_includes recipe, "--agent #{BlockRecipe::UNKNOWN_SOUL}",
                        "#{name} built from #{blank.inspect} must show the blank, not omit the flag:\n#{recipe}"
      end
    end
  end

  # The blank must be unmistakable. A placeholder shaped like a real soul slug
  # (lowercase, hyphens) would be pasted and RECORDED as a soul named after itself —
  # the same unattributed-author failure wearing a name.
  def test_the_visible_blank_cannot_be_mistaken_for_a_soul
    refute_match(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, BlockRecipe::UNKNOWN_SOUL,
                 "the placeholder is shaped like a soul slug, so a paste would record it as one")
    assert_includes BlockRecipe::UNKNOWN_SOUL, "<", "the placeholder must read as a fill-in"
  end

  def each_recipe(agent:)
    names = BlockRecipe::TEMPLATES.keys
    assert_operator names.size, :>=, MINIMUM_RECIPES, "swept #{names.size} recipe(s) — the table went empty"

    names.each { |name| yield name, BlockRecipe.build(name, SLUG, agent: agent) }
  end
end
