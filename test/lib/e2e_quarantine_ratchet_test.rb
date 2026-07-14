# frozen_string_literal: true

# THE RATCHET on the e2e suite's @quarantine hole.
#
# CI runs the Playwright lane with `--grep-invert @quarantine` (.github/workflows/ci.yml),
# excluding the 18 specs that were already RED on an untouched `release` checkout the day
# the lane was switched on. That exclusion buys the healthy 51 specs a real lane TODAY
# instead of holding them hostage to a repair — but it opens a hole, and until this file
# existed the hole was UNBOUNDED.
#
# WHY A NORM WAS NOT ENOUGH. playwright.config.js says, in terms: "Never tag a spec
# @quarantine to get a PR green." That is a NORM, and the entire thesis of the PR that
# wired this lane (#543) is that A NORM IS NOT A GATE. Mutation-confirmed in review:
# appending one word to a healthy spec's title drops the lane from 51 specs to 50, CI stays
# green, and NO guard in the repo notices. A builder with a red spec and a deadline has a
# one-word, zero-friction, entirely silent escape hatch — which is the self-declaration
# disease this whole PR exists to cure, reintroduced by the cure itself.
#
# So the exclusion is bounded MECHANICALLY. The count may fall; it may never rise. That
# turns /tasks/repair-rotted-e2e-specs from an aspiration into something the pipeline
# actually holds you to, and it makes the ONLY way to green a red spec the honest one:
# fix it, or block on it.
#
# TO REPAIR A SPEC: drop its ` @quarantine` tag and lower CEILING to the new count in the
# same commit. The ratchet-down assertion below will tell you the number. When CEILING
# reaches 0, delete the `--grep-invert @quarantine` flag from ci.yml, delete this file,
# and the suite is whole again.
#
# Run directly:
#   ruby -Itest test/lib/e2e_quarantine_ratchet_test.rb
#
# Two tiers (backend shape):
#   [unit]        the tag counter, over fixture spec text (a tag in a TITLE counts; the
#                 word in a comment or in the grep-invert flag itself does not).
#   [integration] the REAL committed e2e/ suite is at or under the ceiling.

require "minitest/autorun"

class E2eQuarantineRatchetTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  E2E_DIR = File.join(ROOT, "e2e")

  # THE RATCHET. 18 specs of 69 were rotted when the lane was wired (2026-07-13). This
  # number may only ever go DOWN. Raising it re-opens the hole this file exists to close,
  # and no reviewer should let it past without a very loud reason.
  CEILING = 18

  # A spec is quarantined by carrying `@quarantine` in its TITLE — that is what Playwright's
  # `--grep-invert @quarantine` matches (it greps the full test title). Count the tag where
  # it is load-bearing: inside a test/describe title string. A stray mention in a code
  # comment excludes nothing and must not inflate the count, or the ratchet drifts loose
  # from the thing it bounds.
  TAGGED_TITLE = /^\s*(?:test|it|describe)(?:\.\w+)*\s*\(\s*(?<q>["'`])(?<title>.*?)\k<q>/

  def quarantined_titles(source)
    source.lines.filter_map do |line|
      match = line.match(TAGGED_TITLE)
      next unless match

      match[:title] if match[:title].include?("@quarantine")
    end
  end

  def committed_quarantine_count
    Dir.glob(File.join(E2E_DIR, "**", "*.spec.js")).sum do |path|
      quarantined_titles(File.read(path)).size
    end
  end

  # --- [unit] the counter ------------------------------------------------------------

  def test_unit_counts_a_tag_in_a_test_title
    source = <<~JS
      test("board shows the card @quarantine", async ({ page }) => {});
      test("board filters by agent", async ({ page }) => {});
    JS
    assert_equal ["board shows the card @quarantine"], quarantined_titles(source)
  end

  def test_unit_ignores_the_word_outside_a_title
    # The flag in ci.yml and the prose in playwright.config.js both contain the literal
    # string. A naive `grep -c @quarantine` over the tree counts those and reads high — a
    # ratchet with slack in it, which would let a real tag slip in under the ceiling.
    source = <<~JS
      // Never tag a spec @quarantine to get a PR green.
      test("board filters by agent", async ({ page }) => {});
    JS
    assert_empty quarantined_titles(source)
  end

  def test_unit_counts_tags_across_describe_and_it_forms
    source = <<~JS
      describe("live updates @quarantine", () => {
        it("streams a new card @quarantine", async () => {});
      });
      test.skip("unrelated", async () => {});
    JS
    assert_equal 2, quarantined_titles(source).size
  end

  # --- [integration] the real committed suite ----------------------------------------

  # ==== THE RATCHET ===================================================================
  def test_integration_the_quarantine_hole_never_grows
    count = committed_quarantine_count

    assert_operator count, :<=, CEILING,
                    "#{count} specs under e2e/ carry @quarantine, over the ceiling of " \
                    "#{CEILING}. CI runs the e2e lane with `--grep-invert @quarantine`, so " \
                    "every tag you add SILENTLY DELETES a spec from the only lane that runs " \
                    "it — the check stays green over less and less. Tagging a spec to get a " \
                    "PR green is the exact self-declaration disease this lane was built to " \
                    "cure; playwright.config.js asks you not to, but a norm is not a gate, " \
                    "which is why this ratchet exists. Two honest moves, no third: FIX the " \
                    "spec, or BLOCK on it."
  end

  # The other half of a real ratchet. Without this, a repair drops the count to 13 while
  # CEILING stays 18 — and the hole can silently RE-GROW to 18 later. Bounded is not the
  # same as shrinking. Forcing the constant down in the same commit as the repair is what
  # makes "the hole can only ever shrink" literally true.
  def test_integration_a_repaired_spec_ratchets_the_ceiling_down
    count = committed_quarantine_count

    assert_equal CEILING, count,
                 "the @quarantine count is #{count} but CEILING is #{CEILING}. You repaired " \
                 "#{CEILING - count} spec(s) — thank you — now LOWER CEILING to #{count} in " \
                 "this same commit. Otherwise the hole you just shrank can quietly grow back " \
                 "to #{CEILING} and no guard will say a word. When CEILING hits 0, drop the " \
                 "`--grep-invert @quarantine` flag from .github/workflows/ci.yml and delete " \
                 "this file: the suite is whole. (/tasks/repair-rotted-e2e-specs)"
  end
  # ====================================================================================
end
