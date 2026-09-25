# frozen_string_literal: true

require "test_helper"

# Guard for the REVIEW-SIDE BASE DOCTRINE (/tasks/review-refuses-unread-base,
# hub PR 1394). `StackedPr.guard_base` is the merge-time gate, and it inverted
# from ONE refusal condition to FIVE: at a merge, anything the guard cannot
# PROVE refuses. Only `base == accepted` proceeds; only a base PROVEN unclaimed
# self-heals by retargeting.
#
# THE FAILURE THIS EXISTS TO PREVENT is prose that claims FOUR arms where the
# code has FIVE. That is exactly how the doctrine shipped: the behavioural fix
# was complete and mutation-killed on all five arms while four prose sites still
# described the old one-condition policy, and a Carl EXECUTES from those sites.
#
# So the arm count is DERIVED FROM THE CODE, never hardcoded here. Add a sixth
# refusal to #guard_base and this test fails until every doc that enumerates the
# set names it too — the prose cannot silently strand behind the gate again.
#
# NOT GUARDED, ON PURPOSE: `bin/ship` is deliberately OPPOSITE on doubt (doubt ⇒
# REPAIR, because ship never merges). That asymmetry is the design, so nothing
# here asserts against ship's arm or its prose.
class BaseRefusalArmsDocsTest < ActiveSupport::TestCase
  ROOT   = Rails.root
  AGENTS = ROOT.join("docs", "agents")

  STACKED_PR = ROOT.join("bin", "lib", "stacked_pr.rb")
  PR_REVIEW  = ROOT.join("bin", "pr-review")

  COUNT_WORDS = %w[zero one two three four five six seven eight nine ten].freeze

  # Each refusal arm, keyed by a distinctive token in its OWN refusal message
  # inside #guard_base, paired with the shapes the prose is allowed to use for
  # it. The code token is what ties the arm to the gate; the doc matcher is what
  # the enumerating prose must satisfy.
  ARMS = {
    "base read failed" => {
      code: /could not be READ/,
      docs: /base read failed|failed base read|base (?:could not|cannot) be read|read of the base failed/i
    },
    "repo scope underivable" => {
      code: /repo to probe could not be derived/,
      docs: /repo to probe|which repo to probe|repo scope could not|cannot tell which repo/i
    },
    "base empty" => {
      code: /came back EMPTY/,
      docs: /came back empty|an empty base|base is empty|base came back empty/i
    },
    "probe unreadable" => {
      code: /could not be determined whether/,
      docs: /unreadable probe|probe (?:was |could not be |is )?unread|probe could not be read|probe errors/i
    },
    "base is another open PR's head" => {
      code: /deliberate STACK/,
      docs: /stack|another open PR's head/i
    }
  }.freeze

  # Every doc surface that ENUMERATES the review-side refusal set. A doc that
  # merely mentions a mis-based PR in passing is not on this list — only the
  # ones that spell the set out, because those are the ones a reader counts.
  #
  # index.md left this list on 2026-09-24 (agents-map-two-hundred-lines): it became
  # a ~200-line map that names no refusal arm, so it no longer enumerates the set.
  # Its old enumeration is frozen in archive/entry-docs-2026-09-24.md; the two SOPs
  # below still spell the set out and stay guarded.
  ENUMERATING_DOCS = [
    "agents/carl/sops/pr-review.md",
    "agents/carl/sops/pr-review-primary.md"
  ].freeze

  # Markdown-emphasis-insensitive read: drop * and ` so bold/italic/code emphasis
  # can't break a phrase match, and collapse whitespace so a line-wrapped
  # sentence still matches as one run.
  def norm(text)
    text.gsub(/[*`]/, "").gsub(/\s+/, " ")
  end

  def doc(rel)
    norm(File.read(AGENTS.join(rel)))
  end

  # The body of #guard_base — the gate itself, sliced off at the next top-level
  # `end` so a later method's refusals can never inflate the count.
  def guard_base_body
    src = File.read(STACKED_PR)
    from = src.index("def guard_base")
    assert from, "bin/lib/stacked_pr.rb no longer defines guard_base"
    src[from..].split(/^  end$/, 2).first
  end

  # How many arms the CODE actually has, counted at the refusal call sites.
  def code_arm_count
    guard_base_body.scan(/\brefuse\(say,/).length
  end

  test "[static] every refusal arm this test knows is still a live arm of guard_base" do
    body = guard_base_body

    ARMS.each do |name, spec|
      assert_match spec[:code], body,
                   "#{name}: guard_base no longer carries this refusal — retire or re-key the arm here"
    end

    assert_equal ARMS.length, code_arm_count,
                 "guard_base has #{code_arm_count} refusal arm(s) but this test knows #{ARMS.length}. " \
                 "A new arm was added: name it in ARMS, then in every doc in ENUMERATING_DOCS."
  end

  test "[static] guard_base's own enumerated list names one item per refusal arm" do
    src = File.read(STACKED_PR)
    heading = src[/#\s*(\w+) THINGS MUST BE PROVEN[^\n]*\n((?:\s*#[^\n]*\n)+)/]
    assert heading, "bin/lib/stacked_pr.rb lost its 'THINGS MUST BE PROVEN' enumeration"

    word  = Regexp.last_match(1).downcase
    items = Regexp.last_match(2).scan(/^\s*#\s+\d+\.\s/).length
    expected = COUNT_WORDS[code_arm_count]

    assert_equal expected, word,
                 "the heading says #{word.upcase} THINGS MUST BE PROVEN but guard_base has " \
                 "#{code_arm_count} refusal arms"
    assert_equal code_arm_count, items,
                 "the numbered list has #{items} item(s) for #{code_arm_count} refusal arms — " \
                 "every arm refuses on its own, so every arm needs its own item"
  end

  test "[static] stacked_pr.rb's spelled-out arm counts match the code" do
    expected = COUNT_WORDS[code_arm_count]

    File.read(STACKED_PR).scan(/(?:full list of|each of these)\s+(\w+)/i) do |(word)|
      assert_equal expected, word.downcase,
                   "stacked_pr.rb points the reader at a list of #{word} refusals, " \
                   "but guard_base has #{code_arm_count}"
    end
  end

  test "[static] every doc that enumerates the base refusals names ALL of them" do
    ENUMERATING_DOCS.each do |rel|
      body = doc(rel)

      assert_match(/PROVEN unclaimed|proven unclaimed/i, body,
                   "#{rel}: the self-heal must be qualified as proven-unclaimed only")

      ARMS.each do |name, spec|
        assert_match spec[:docs], body,
                     "#{rel} does not name the '#{name}' refusal arm. At a merge anything " \
                     "unproven REFUSES — a doc short one arm reads as a doc that permits it."
      end
    end
  end

  test "[static] merge_feature_pr's doc comment does not promise an unqualified self-heal" do
    src = File.read(PR_REVIEW)
    from = src.index(/^#[^\n]*\n(?:#[^\n]*\n)*def merge_feature_pr/)
    assert from, "bin/pr-review no longer carries a doc comment above merge_feature_pr"

    comment = norm(src[from...src.index("def merge_feature_pr")])

    assert_match(/self-heal/i, comment, "the doc comment should still describe the self-heal")
    assert_match(/PROVEN|proven/, comment,
                 "merge_feature_pr's doc comment describes the self-heal without the PROVEN " \
                 "qualifier — read alone it states the pre-1394 doctrine the body contradicts")
    assert_match(/refus/i, comment,
                 "the doc comment must say that an unproven base REFUSES, not just that a " \
                 "mis-based one retargets")
  end

  test "[static] the hand-run merge block qualifies the retarget it tells a Carl to expect" do
    line = File.readlines(AGENTS.join("agents/carl/sops/pr-review.md"))
           .find { |l| l.include?("gh pr merge <feat-pr>") }
    assert line, "pr-review.md lost its hand-run `gh pr merge` line"

    assert_match(/proven/i, norm(line),
                 "the hand-run merge comment tells a Carl a mis-based PR 'retargets first' " \
                 "without the proven-unclaimed qualifier — it reads as 'retarget anything " \
                 "that is not a stack', which is the fail-open PR 1394 closed")
    refute_match(/bullett/, line, "typo: 'bullett'")
  end
end
