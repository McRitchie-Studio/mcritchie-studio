# frozen_string_literal: true

# [docs] THE BOARD DOC TEACHES ONE LADDER.
#
# THE DEFECT (board-doc-teaches-old-ladder, 2026-09-10). docs/agents/modules/devops-task-board.md
# contradicted ITSELF: its approval-gate and fast-lane sections taught the current ladder
# (a feature PR into `accepted`; review MERGES it there; `reviewed` ⟺ code on `accepted`),
# while its Stage Flow callout, stage table, branch row, task-tracking steps and a whole
# "QA / Avi Duties" section still taught the retired one — PRs based on `release`, "do not
# merge during review", Avi as the reviewer. devops-cycle-design.md's header said the same
# about `finish --pr`. An agent reading either half was right by that half and wrong by
# the other.
#
# KEYED ON CLAIMS, NEVER ON LINE NUMBERS. Several PRs touch this file every night; a guard
# pinned to a line either breaks on the next edit or stops looking at the sentence it was
# written for. Each claim below is a predicate over one sentence or table cell, so a
# retired claim fails wherever it reappears, however the file around it moves.
#
# THE GUARD IS A FUNCTION OF TEXT, and it is run against the retired sentences verbatim
# (test_the_guard_flags_every_retired_sentence): a guard that has never been shown to fail
# on the real regression is a guard nobody has tested.
#
#   bin/rails test test/docs/board_doc_ladder_test.rb
require "minitest/autorun"

class BoardDocLadderTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  # The board doc is read WHOLE. devops-cycle-design.md is read only up to its first
  # `## ` heading: that header states what is IMPLEMENTED (it is where `finish --pr ...
  # --base release` sat), while the body is an architecture record that keeps its
  # history deliberately, under its own note on how to read the retired target.
  DOCS = {
    "docs/agents/modules/devops-task-board.md" => :whole,
    "docs/agents/system/devops-cycle-design.md" => :header
  }.freeze

  REVIEW_WORD = /\b(review|scout)/i

  # The three claims the current ladder makes false. Each is a predicate over ONE unit.
  CLAIMS = {
    # A feature PR is based on (or merged into) `release`. The batch promote PR IS based
    # on `release` — that is the qa-release sweep, not a feature PR — so a unit that names
    # the batch or the promote is not this claim.
    "a feature PR is based on `release`" => lambda do |unit|
      based = unit.match?(/\bbase\b[^.]{0,24}`?release\b|--base\s+`?release\b/i) ||
              unit.match?(/\b(PR|pull request)\b[^.]{0,60}\binto\s+`?release\b/i)
      based && !unit.match?(/\bbatch\b|\bpromot/i)
    end,
    # Review does not merge. It does: the primary merges merge-ready work into `accepted`.
    "review does not merge" => lambda do |unit|
      unit.match?(REVIEW_WORD) && unit.match?(/\b(do not|don't|does not|doesn't|never|must not|without)\s+merg/i)
    end,
    # Avi owns review. Review is Carl's pr-review lane; Avi owns qa-release. Avi must be
    # the one the review ownership is pinned to — "a human Carl/Avi/Steffon session" or
    # "the interrupted-Avi skip" mention Avi near review without claiming he owns it.
    "Avi owns review" => lambda do |unit|
      unit.match?(/\bAvi\b(?:'s)?[^.;]{0,50}\b(reviewer|review (resolution|decision)|final (PR )?review|final call|owns review)/i)
    end
  }.freeze

  # The retired sentences, VERBATIM from origin/accepted before the fix. Each must be
  # flagged for the claim named beside it, or the guard cannot catch its own regression.
  RETIRED = [
    ["a feature PR is based on `release`",
     "| `branch` | The feature branch (opened as a PR with base `release`). The shared integration branch is the persistent per-repo `release` (same name everywhere). |"],
    ["a feature PR is based on `release`",
     "> the persistent-`release` branch model, **`reviewed`** = an approved PR whose\n> base is `release`, and **`assembled`** = that PR merged into `release`"],
    ["a feature PR is based on `release`",
     "> branch from `origin/release` (falling back to `origin/main` where no `release`\n> branch exists) and `finish --pr` opens the PR with `--base release`."],
    ["a feature PR is based on `release`",
     "| `assembled` | PR is merged into `release` and included in the QA candidate |"],
    ["review does not merge", "5. Move only approved PRs to `reviewed`; do not merge during review."],
    ["review does not merge",
     "`conductor-review`. Scouts do not merge, deploy, move task stages, publish\ngems, change providers, rotate credentials, force-push, or take over branches."],
    ["Avi owns review",
     "review; they do not transfer release authority. Avi owns review resolution and\nproduction ship, while Avi's `qa-release` sweep owns merge plus QA deploy."],
    ["Avi owns review",
     "- `merge-ready` means scout evidence and qa-intake are aligned; Avi still\n  performs the final PR review before moving the task to `reviewed`."],
    ["Avi owns review",
     "accidentally turning a scout's recommendation into Avi's final review decision."]
  ].freeze

  # The current model, stated the way the fixed doc states it. None may be flagged — a
  # guard that fires on the truth gets deleted, and then it guards nothing.
  CURRENT = [
    "A feature PR targets **`accepted`**; **`reviewed`** = review merged it there (`reviewed` ⟺ code on `accepted`).",
    "It promotes all of `accepted` onto `release` in one batch PR per repo, deploys QA, and flips members to `assembled` only on QA-green.",
    "On `merge-ready` it merges the feat PR into `accepted` (`gh pr merge --merge`) and moves the task to `reviewed`.",
    "Review is not Avi's.",
    "A low-confidence reviewer marks `conductor-review` and routes to a human Carl/Avi/Steffon session instead.",
    "| QA release | Avi | qa-release | promotes all of `accepted` onto `release` (one batch PR per repo) |"
  ].freeze

  # One sentence or table cell per unit, whitespace collapsed, so a claim wrapped across
  # lines — or split across a blockquote's `>` markers — is still read as one claim.
  def units(text)
    text.gsub(/^\s*>\s?/, "")
        .split(/\n\s*\n|\|/)
        .flat_map { |para| para.gsub(/\s+/, " ").split(/(?<=[.!?;])\s+(?=[A-Z`*(\[0-9-])/) }
        .map(&:strip)
        .reject(&:empty?)
  end

  def violations(text)
    units(text).flat_map { |unit| CLAIMS.select { |_, holds| holds.call(unit) }.keys.map { |claim| [claim, unit] } }
  end

  def scoped_text(rel, scope)
    text = File.read(File.join(ROOT, rel))
    scope == :header ? text.split(/^## /, 2).first : text
  end

  def test_the_board_docs_teach_the_accepted_ladder
    DOCS.each do |rel, scope|
      found = violations(scoped_text(rel, scope))
      assert_empty found,
                   "#{rel} teaches the RETIRED ladder:\n" +
                   found.map { |claim, unit| "  [#{claim}] #{unit[0, 220]}" }.join("\n") +
                   "\nThe current model: feature PRs target `accepted`; review merges merge-ready work there " \
                   "(`reviewed` ⟺ code on `accepted`); qa-release promotes `accepted` onto `release`."
    end
  end

  def test_the_guard_flags_every_retired_sentence
    RETIRED.each do |claim, sentence|
      assert_includes violations(sentence).map(&:first), claim,
                      "the guard must flag this retired sentence as [#{claim}], or it cannot catch its own " \
                      "regression:\n  #{sentence}"
    end
  end

  def test_the_guard_passes_the_current_model
    CURRENT.each do |sentence|
      assert_empty violations(sentence), "the guard flags a TRUE statement of the current model:\n  #{sentence}"
    end
  end

  def test_the_guard_reads_real_text
    # A split that produced nothing would pass every assertion above over air.
    DOCS.each do |rel, scope|
      floor = scope == :header ? 5 : 50
      assert_operator units(scoped_text(rel, scope)).size, :>, floor, "#{rel} (#{scope}) split into almost nothing"
    end
  end
end
