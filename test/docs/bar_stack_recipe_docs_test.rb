# frozen_string_literal: true

require "test_helper"

# GUARD (resync-bar-stack-doc, 2026-08-11): the onboarding SOP's bar-stack recipe
# is what a NEW app copies into its layout, so a stale recipe here ships a broken
# app rather than a stale sentence.
#
# It has already drifted once. 0.33 introduced `--studio-bars-h` — the stack
# measured itself and the navbar's sticky `top` read the published value — and
# this SOP taught exactly that, down to "no `top-0` class to fight it". 0.39
# REMOVED the property (it made the header jump after first paint and draw twice
# under a view transition): bars now sit in normal flow and the navbar is a static
# `sticky top-0`. For the window between those releases, following this SOP would
# have put a hand-written navbar UNDERNEATH the sticky bars.
#
# WHY THE ASSERTIONS BELOW ARE SHAPED THIS WAY. The obvious test — refute the doc
# mentions `--studio-bars-h` — is a negative grep, and it fails twice over:
#
#   1. It passes if someone DELETES the whole bullet. Absence is not correctness,
#      so every refutation here is paired with a positive claim about what the
#      recipe must still teach.
#   2. The doc legitimately NAMES the retired property, to tell an already-adopted
#      app that its `top:var(--studio-bars-h, 0px)` needs no edit (it resolves to
#      the 0px fallback). A bare refutation would flag the correct text.
#
# So the property asserted is not "the string is absent" but "the recipe teaches a
# STATIC pin, and any mention of the retired variable is pinned to a version floor
# at or past the release that removed it." Writing `>= 0.33` next to a top-0 recipe
# fails, which is the exact drift that happened.
class BarStackRecipeDocsTest < ActiveSupport::TestCase
  SOP = Rails.root.join("docs", "agents", "system", "new-app-onboarding-sop.md")

  # The release that deleted the measured custom property (studio-engine
  # CHANGELOG 0.39.0, "Removed: `--studio-bars-h` is gone").
  PROPERTY_REMOVED_IN = Gem::Version.new("0.39")

  setup do
    body = SOP.read
    # Scope to the bullet, not the file: the SOP is long, and a match anywhere
    # else would let the recipe itself rot unnoticed.
    @recipe = body[/^- \*\*Render the shared bar stack.*?(?=^- \*\*|^\*\*Standalone)/m]
    refute_nil @recipe, "the bar-stack bullet must exist — deleting it is not a way to pass this test"
  end

  test "the recipe teaches the static pin" do
    assert_includes @recipe, "sticky top-0",
                    "a hand-written navbar must be told to pin statically"
    assert_includes @recipe, "normal flow",
                    "the bars reserve their space by occupying it — that is the whole mechanism"
    assert_includes @recipe, "**static**",
                    "the doc must say the value is static, not leave it to be inferred"
  end

  test "the recipe still renders the stack before the navbar, as a sibling" do
    stack_at = @recipe.index(%(render "studio/banners/stack"))
    navbar_at = @recipe.index(%(render "layouts/navbar"))

    refute_nil stack_at, "the recipe must show the render call a new app copies"
    refute_nil navbar_at
    assert_operator stack_at, :<, navbar_at,
                    "the stack is the navbar's sibling, rendered immediately above it"
    assert_includes @recipe, "sibling"
  end

  # The version floor is what makes the recipe safe to follow. It is asserted as a
  # NUMBER, not a string: `>= 0.33` and `>= 0.39` differ by one character and by
  # whether the app that copies this boots with its navbar under the bars.
  test "the engine floor is at or past the release that removed the property" do
    named = @recipe[/studio-engine >= (\d+\.\d+)/, 1]

    refute_nil named, "the recipe must name the engine floor it depends on"
    assert_operator Gem::Version.new(named), :>=, PROPERTY_REMOVED_IN,
                    "a floor below #{PROPERTY_REMOVED_IN} still publishes --studio-bars-h, " \
                    "so this recipe's static top-0 would sit under the bars"
  end

  # A var()-derived `top` is the defect class: whatever the property is called,
  # reading the offset from something published at runtime brings the jump back.
  #
  # The recipe legitimately contains exactly ONE — the reassurance that an
  # already-adopted navbar's `top:var(--studio-bars-h, 0px)` needs no edit. So the
  # invariant is a CENSUS, not a context sniff: one occurrence, and it is the known
  # legacy one.
  #
  # An earlier cut of this test scored each occurrence by whether retiring words
  # ("removed", "gone", "fallback") appeared within a ±220 character window. Two
  # mutations walked straight through it — a fresh `top:var(--studio-chrome-h)`
  # planted next to the legacy sentence inherited that sentence's retiring words
  # and scored as history. A window is a PROXY for "this is described, not
  # prescribed"; the count is the property itself.
  OFFSET_FROM_PROPERTY = /top:\s*var\(/
  KNOWN_LEGACY = "top:var(--studio-bars-h, 0px)"

  test "the only var()-derived top in the recipe is the retired one" do
    found = @recipe.scan(/top:\s*var\([^)]*\)/)

    assert_equal 1, found.length,
                 "expected exactly one var()-derived top — the legacy reassurance. " \
                 "Extra or missing occurrences both mean drift: #{found.inspect}"
    assert_equal KNOWN_LEGACY, found.first,
                 "the one permitted occurrence is the retired property, named so an " \
                 "adopted app knows its existing spelling is harmless"
    assert_match(/needs no edit|fallback|gone/, @recipe[/#{Regexp.escape(KNOWN_LEGACY)}.{0,120}/m],
                 "it must be marked retired in the same breath, not left looking prescriptive")
  end
end
