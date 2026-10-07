# frozen_string_literal: true

require "test_helper"

# The two entry docs keep the SOP invocation standard ahead of the generic rules, so
# an SOP name resolves before triage. This is a property of the entry docs' order,
# not a copy of any code, so it stays a test.
#
# The review-lane command shapes are no longer pinned here: `bin/reviewer-select
# --help` prints the `--no-record` preview, `bin/task intent --to reviewed` prints
# the claim it does not take (test/lib/task_cli_test.rb), and
# docs/agents/modules/pr-review-sop.md cites the exit-10 arms and the lease by seam.
class ReviewLaneDocsTest < ActiveSupport::TestCase
  AGENTS = Rails.root.join("docs", "agents")

  # Markdown-emphasis-insensitive read: drop * and ` so bold/italic/code emphasis
  # can't break a phrase match, and collapse whitespace so a line-wrapped sentence
  # still matches as one run.
  def norm(rel)
    File.read(AGENTS.join(rel)).gsub(/[*`]/, "").gsub(/\s+/, " ")
  end

  test "[static] generated agent entrypoint defines the SOP invocation standard before generic triage" do
    body = norm("index.md")
    standard = body.index("SOP Invocation Standard")
    first_rules = body.index("First Rules")
    assert standard, "index.md must expose the SOP invocation standard near the top"
    assert first_rules, "index.md must keep First Rules after the SOP standard"
    assert_operator standard, :<, first_rules,
      "SOP names must resolve before the broader operating rules can send agents into generic triage"
  end

  test "[static] claude adapter also points SOP invocations to AGENTS standard first" do
    body = norm("claude.md")
    standard = body.index("SOP invocation standard")
    devops_gate = body.index("STOP — before writing ANY code")
    assert standard, "Claude adapter must expose SOP routing before the DevOps gate"
    assert devops_gate, "Claude adapter must keep the DevOps gate"
    assert_operator standard, :<, devops_gate,
      "SOP prompts must be resolved before generic workflow handling"
  end
end
