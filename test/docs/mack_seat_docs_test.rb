# frozen_string_literal: true

require "test_helper"

# [docs] Mack's seat (CFO, task mack-finance-seat): the subagent definition a
# spawned Mack reads is the only copy of his rules he sees, so it must carry
# the ones that keep the books true, and be installable from his role page. His
# heartbeat's weekly watch must read every entity's status.
class MackSeatDocsTest < ActiveSupport::TestCase
  MACK = Rails.root.join("docs", "agents", "agents", "mack")

  def norm(rel) = File.read(MACK.join(rel)).gsub(/[*`]/, "").gsub(/\s+/, " ")

  test "[docs] the subagent definition carries the CFO's rules and the Worker class" do
    agent = norm("claude-agent.md")

    assert_match(/\A---\s*name: mack\b/, agent)
    assert_match(/Record only Alex McRitchie's answers, with a citation/, agent)
    assert_match(/Never guess a classification/, agent)
    assert_match(/Cannot confirm or refute/i, agent)
    assert_match(/Never print an account number/, agent)
    assert_match(/Worker class: no admin vault/, agent)
    assert_match(/finance vault .* is Steffon's to create/, agent)
    assert_match(%r{bin/books lender <entity> <YYYY-MM>}, agent)
    assert_includes norm("role.md"), "docs/agents/agents/mack/claude-agent.md /Users/alex/.claude/agents/mack.md"
  end

  test "[docs] the heartbeat's weekly watch reads every entity and names what it raises" do
    beat = norm("HEARTBEAT.md")

    assert_match(/weekly, on Monday/, beat)
    assert_match(%r{bin/books status <entity> for every entity}, beat)
    [ "Unanswered lines", "Statements missing", "A cash drop" ].each { |raise| assert_includes beat, raise }
  end
end
