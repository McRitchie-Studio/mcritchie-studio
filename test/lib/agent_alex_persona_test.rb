require "test_helper"
require Rails.root.join("bin/lib/agent_mailbox").to_s

# [unit] alex-persona-polish: the Buy Then Build floor and Alex McRitchie's three
# lines the persona must carry faithfully (.agents/epics/alex-persona.md,
# answers 3 and 5). The rule is code (AlexPersona::RULES), so an edit to the page
# cannot drop it; the lines are on the page, so a test pins them there.
class AgentAlexPersonaTest < ActiveSupport::TestCase
  P = AgentMailbox::AlexPersona

  def page = P.page(Rails.root.to_s)

  test "the floor opens his buy-then-build philosophy and published criteria" do
    assert_includes P::RULES, "- BUY THEN BUILD. His philosophy of buying a business is public and yours to discuss"
    assert_includes P::RULES, "why buying\n    a good service business beats a startup (Walker Deibel's *Buy Then Build*)"
    assert_includes P::RULES, "the criteria\n    the persona publishes"
  end

  test "the floor closes every specific deal: business, counterparty, lender, price, status" do
    assert_includes P::RULES, "A specific deal never is: no business, counterparty, lender, price or\n    status, not even a hint that one exists."
    assert_includes P::RULES, "The always-rule against discussing deals means that."
    assert_includes P::RULES, "Never share deals in progress (any business being bought)", "the older floor line stands"
  end

  test "the floor never says acquisition: the public-prompt guard allows it only in the always-rule" do
    refute_match(/acquisition/i, P::RULES)
    refute_match(/acquisition/i, P::BUILD_RULE)
    refute_match(/acquisition/i, page)
  end

  test "the floor prints on every alex block, /build included" do
    [ P.block(repo_root: Rails.root.to_s), P.block(repo_root: Rails.root.to_s, build: true) ].each do |block|
      assert_includes block, "- BUY THEN BUILD."
      assert_operator block.index("- BUY THEN BUILD."), :<, block.index(P::HEAD), "the rule sits above the page"
    end
  end

  test "the page carries his three lines faithfully" do
    assert_includes page, "win-win scenarios", "answer 5, his phrase"
    assert_includes page, "\"I feel like I was one of the first of my friends to wholly give my development cycle to AI.\"",
                    "answer 3, verbatim"
    assert_includes page, "Tests matter at every level: unit, integration, UI.", "answer 3"
    assert_includes page, "\"Almost all tests are an important part of a stack, especially when building through steering.\"",
                    "answer 3, verbatim"
  end

  test "the page carries the philosophy and published criteria the rule opens" do
    assert_includes page, "Walker Deibel's *Buy Then Build*"
    assert_includes page, "$1M to $5M in revenue, 10+ years in business"
  end

  test "the page names no private contact: no resume phone, no personal email, no studio mailbox" do
    refute_match(/\(\d{3}\)\s*\d{3}-\d{4}|\d{3}[-.]\d{3}[-.]\d{4}/, page)
    refute_match(/@/, page)
    refute_includes P::RULES, "alex@mcritchie.studio"
  end

  test "the shipped page still fits the 4,000-character cap uncut" do
    assert_equal 4000, P::BUDGET
    assert_operator page.length, :<=, P::BUDGET
  end
end
