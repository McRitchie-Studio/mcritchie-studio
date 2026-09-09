# frozen_string_literal: true

require "test_helper"

# GUARD (sop-precondition-blocks-sharing, 2026-09-09): the `share-insights` SOP's
# ENTRY CONDITION must be the condition the generator actually applies.
#
# THE DEFECT. Preconditions said to stop unless an insight had been "confirmed by
# Mr. McRitchie (`grader: \"mcr\"`)". Insights::DocGenerator.banked_insights reads
# ActionGrade.banked and applies NO grader filter, and all five live insights are
# Alex-graded — so the SOP told its own agent "nothing to share" while the bank it
# exists to publish was full. The prose was the wrong half: `grader` records WHO
# WROTE THE ROW (the `mcr` row is McRitchie's audit OF Alex's grade, admin-only by
# design — the agent API always grades as `alex`), while `#bank!` is the curation
# act. Both other readers of the bank agree with the generator: ActionGrade
# .insight_feed (the /api/v1/insights SessionStart feed) and HeartbeatController
# #insights both read `banked` with no grader filter.
#
# WHY THIS IS NOT A GREP. Grepping the SOP for the retired sentence proves nothing
# — the sentence gets reworded. Grepping doc_generator.rb for ".banked" proves
# nothing about the prose. So the SOP now STATES its gate as an executable
# expression, and this guard EXECUTES it and holds the resulting set equal to what
# the generator publishes over the same bank. That pins the two together in BOTH
# directions:
#
#   · narrow the QUERY (add `.by_grader("mcr")` to the generator) → the sets
#     diverge → red, naming the SOP as the thing to reconcile;
#   · narrow the PROSE (write a grader filter into the SOP's fence) → this guard
#     runs THAT expression instead, and it diverges from the generator → red.
#
# Neither half can be "fixed" alone, which is the property the incident wanted.
#
# WHAT THIS GUARD IS NOT. It is not a freshness check. Insights::DocFreshness
# (/tasks/insights-doc-never-regenerated) already detects a stale artefact on the
# board, CAUSALLY — the bank curated after the doc was generated — and this file
# deliberately adds no calendar bound beside it. It also never counts the LIVE
# bank: CI's database has no action_grades fixtures, so a live-count assertion
# could only fail on every PR or pass vacuously. Every row read here is seeded by
# the test.
class ShareInsightsPreconditionDocsTest < ActiveSupport::TestCase
  SOP = Rails.root.join("docs/agents/agents/alex/sops/share-insights.md")

  # The stated gate lives in the ONE ```ruby fence inside `## Preconditions`.
  RUBY_FENCE = /^```ruby\s*\n(.*?)^```\s*$/m

  # A conservative grammar for that expression: `ActionGrade` plus one or more
  # scope segments, each optionally taking a single quoted word. No dots inside
  # arguments (so splitting on "." is safe), no interpolation, no blocks. Anything
  # richer fails LOUDLY below rather than being executed.
  GATE_EXPR = /\AActionGrade(?:\.[a-z_][a-z_0-9]*[?!]?(?:\("[a-z_]+"\))?)+\z/

  # Floors on the prose sweep. A gutted Preconditions section must FAIL here, not
  # sail through on "no forbidden words found in nothing".
  MIN_PRECONDITION_LINES = 4
  MIN_PRECONDITION_CHARS = 200

  def sop_body
    @sop_body ||= begin
      assert SOP.exist?, "#{SOP} is missing — the SOP this guard pins no longer exists"
      SOP.read
    end
  end

  # The `## Preconditions` section, up to the next `## ` heading.
  def preconditions_section
    @preconditions_section ||= begin
      match = sop_body[/^## Preconditions\s*\n(.*?)(?=^## )/m]
      assert match.present?,
             "share-insights.md has no `## Preconditions` section. The SOP's entry condition is what " \
             "this guard pins to Insights::DocGenerator; without the section there is no stated " \
             "condition left to check, and the SOP is free to drift back to a grader gate."
      match
    end
  end

  # The expression the SOP declares as its gate, validated before it is run.
  def stated_gate_expression
    @stated_gate_expression ||= begin
      fence = preconditions_section[RUBY_FENCE, 1]
      assert fence.present?,
             "share-insights.md's Preconditions no longer state their gate as a runnable ```ruby " \
             "expression. That fence is the whole pin: this guard executes it and compares the result " \
             "to what Insights::DocGenerator publishes. State the gate (e.g. `ActionGrade.banked`) or " \
             "this coupling is gone."

      lines = fence.lines.map(&:strip).reject(&:empty?)
      assert_equal 1, lines.size,
                   "expected exactly ONE expression in the Preconditions fence, got #{lines.size}: " \
                   "#{lines.inspect}. The gate is a single set; keep it that way so it can be executed."

      expression = lines.first
      assert_match GATE_EXPR, expression,
                   "the Preconditions fence (#{expression.inspect}) is not a plain ActionGrade scope " \
                   "chain. This guard will only execute the restricted grammar #{GATE_EXPR.source} — a " \
                   "doc is not a place to put code that needs eval. Restate the gate as scopes, or widen " \
                   "this guard deliberately."
      expression
    end
  end

  # Turn the stated expression into a live relation, allowing only methods the
  # model itself defines — so the SOP can never name a scope that is not real.
  def stated_relation
    permitted = ActionGrade.singleton_class.public_instance_methods(false).map(&:to_s).to_set

    stated_gate_expression.delete_prefix("ActionGrade.").split(".").reduce(ActionGrade.all) do |relation, segment|
      name, argument = segment.match(/\A([a-z_0-9?!]+)(?:\("([a-z_]+)"\))?\z/).captures
      assert_includes permitted, name,
                      "share-insights.md's Preconditions name `ActionGrade.#{name}`, which the model does " \
                      "not define. The SOP is describing a gate that does not exist."
      argument ? relation.public_send(name, argument) : relation.public_send(name)
    end
  end

  # One graded row. Each grade needs its own action (grader is unique per action).
  def grade(slug:, grader:, banked:)
    action = AgentAction.capture(session_id: "sop-precond-#{slug.parameterize}", kind: "edit", outcome: "ok")
    row = ActionGrade.create!(agent_action: action, grader: grader, slug: slug, disposition: "good")
    row.bank! if banked
    row
  end

  # A bank shaped like the live one AND like the one the retired precondition
  # assumed: Alex-graded rows (all five live insights are these), a McRitchie
  # audit row, and an unbanked row of each grader. Both axes have to vary or the
  # equality below could pass without ever being at risk.
  def seed_bank
    grade(slug: "alex banked lesson one",  grader: ActionGrade::ALEX, banked: true)
    grade(slug: "alex banked lesson two",  grader: ActionGrade::ALEX, banked: true)
    grade(slug: "mcr audited lesson",      grader: ActionGrade::MCR,  banked: true)
    grade(slug: "alex ungraded leftovers", grader: ActionGrade::ALEX, banked: false)
    grade(slug: "mcr ungraded leftovers",  grader: ActionGrade::MCR,  banked: false)
  end

  # What the SOP says is in scope. Blank slugs are dropped on both sides: the
  # generator drops them as rendering hygiene (a row with no lesson has nothing to
  # print), which is not a narrowing of the gate.
  def stated_slugs
    stated_relation.pluck(:slug).reject { |slug| slug.to_s.strip.empty? }.sort
  end

  def published_slugs
    Insights::DocGenerator.banked_insights.map { |insight| insight[:slug] }.sort
  end

  # ── the pin ────────────────────────────────────────────────────────────────

  test "[docs] the precondition the SOP states is the scope DocGenerator publishes" do
    seed_bank

    stated = stated_slugs
    published = published_slugs

    # Floor on the sweep: the comparison has to be made over a bank that spans
    # both graders and both banked states, or it proves nothing about either.
    assert_operator stated.size, :>=, 3,
                    "share-insights.md states its gate as `#{stated_gate_expression}`, which matches only " \
                    "#{stated.size} of the 3 banked rows seeded here across BOTH graders. Either the prose " \
                    "has narrowed the entry condition below what Insights::DocGenerator publishes — the " \
                    "defect this guard exists for — or the fixture no longer spans the bank, in which case " \
                    "the comparison below would prove nothing."
    assert_equal 2, stated_relation.where(grader: ActionGrade::ALEX).count,
                 "the seeded fixture must keep BOTH Alex-graded banked rows in the stated set — they are " \
                 "the shape of the live bank, and the rows the retired precondition excluded"
    assert_equal 1, stated_relation.where(grader: ActionGrade::MCR).count,
                 "the seeded fixture must keep the McRitchie audit row in the stated set too — the bank " \
                 "holds both graders, and neither one is the gate"

    assert_equal stated, published,
                 "PROSE AND QUERY HAVE DIVERGED. share-insights.md's Preconditions state the entry " \
                 "condition as `#{stated_gate_expression}` (#{stated.size} row(s) here), but " \
                 "Insights::DocGenerator.banked_insights publishes #{published.size}: " \
                 "#{(stated - published).inspect} stated-but-unpublished, " \
                 "#{(published - stated).inspect} published-but-unstated. Whichever half moved, the other " \
                 "owes the same move — an SOP whose entry condition is narrower than the generator tells " \
                 "its agent 'nothing to share' over a bank full of lessons, which is the incident this " \
                 "guard was written for (/tasks/sop-precondition-blocks-sharing)."
  end

  # MUTATION PROOF, run against the same fixture: a grader-filtered generator WOULD
  # be caught. This is the cell that has to be able to falsify — without it the
  # equality above could be green because nothing here can ever differ.
  test "[docs] the comparison detects a grader-narrowed generator" do
    seed_bank

    narrowed = stated_relation.where(grader: ActionGrade::MCR)
                              .pluck(:slug).reject { |slug| slug.to_s.strip.empty? }.sort

    refute_equal stated_slugs, narrowed,
                 "a grader-narrowed set is INDISTINGUISHABLE from the stated set on this fixture, so the " \
                 "pin above cannot fail on the defect it exists to catch. Restore a bank that spans both " \
                 "graders."
    assert_equal stated_slugs, published_slugs,
                 "sanity: the generator is the unnarrowed set, so the mutation above is a real difference"
  end

  # ── the prose half ─────────────────────────────────────────────────────────
  #
  # The pin above compares SETS; these keep the section that states them from
  # being hollowed out to a bare fence, and keep the reason on the page so the
  # grader gate is not re-added as a helpful improvement.

  test "[docs] the Preconditions section still explains why the grader is not the gate" do
    section = preconditions_section
    lines = section.lines.map(&:strip).reject(&:empty?)

    assert_operator lines.size, :>=, MIN_PRECONDITION_LINES,
                    "the Preconditions section is down to #{lines.size} non-blank line(s) — too thin to " \
                    "carry both the gate and why it is the gate"
    assert_operator section.length, :>=, MIN_PRECONDITION_CHARS,
                    "the Preconditions section is #{section.length} chars — it has been hollowed out"

    assert_match(/banked-ness is the gate; the grader is not/i, section,
                 "the Preconditions lost the sentence that settles which column gates publication. " \
                 "Without it, `grader: \"mcr\"` reads like a quality bar rather than what it is — the " \
                 "admin-only audit OF Alex's grade — and gets re-added as an entry condition.")
    assert_match(/audit/i, section,
                 "the Preconditions no longer say that the `mcr` row is McRitchie's AUDIT of a grade")
    assert_match(/nothing to share/, section,
                 "the Preconditions lost the stop instruction — an entry condition with no stop is not a " \
                 "precondition")
  end

  # The retired shape, stated as a REQUIREMENT rather than as history. The section
  # necessarily discusses `grader: "mcr"` in order to reject it, so this looks for
  # the directive form only — a stop keyed on confirmation.
  test "[docs] the SOP does not gate its entry on McRitchie confirmation" do
    directives = [
      /has been confirmed by Mr\. McRitchie/i,
      /at least one insight has been confirmed/i,
      /if none are confirmed/i,
      /only .{0,40}confirmed .{0,40}insights? (are|is) (shared|published|generated)/i
    ]

    directives.each do |pattern|
      refute_match pattern, sop_body,
                   "share-insights.md gates its entry on McRitchie confirmation again (/#{pattern.source}/). " \
                   "Insights::DocGenerator publishes ActionGrade.banked with no grader filter, and the " \
                   "agent write path always grades as `alex` — so this condition stands the SOP down over " \
                   "every lesson an agent can bank."
    end
  end
end
