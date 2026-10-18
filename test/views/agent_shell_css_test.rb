require "test_helper"

# The agent shell's height cap (app/assets/tailwind/agent_shell.css). A browser
# without dvh (iOS before 15.4) drops a 100dvh declaration whole; without a
# 100vh line before it the shell has no cap and the thread never scrolls inside.
class AgentShellCssTest < ActiveSupport::TestCase
  CSS = Rails.root.join("app/assets/tailwind/agent_shell.css")

  test "[component] the shell caps its height in 100vh before 100dvh" do
    rule = CSS.read[/^\.agent-shell \{(.*?)^\}/m, 1] || flunk("no .agent-shell rule")
    caps = rule.lines.map(&:strip).grep(/\Amax-height:/)
    assert_equal [ "max-height: calc(100vh - var(--agent-shell-top, 9rem));",
                   "max-height: calc(100dvh - var(--agent-shell-top, 9rem));" ], caps,
                 "the vh fallback comes first, the dvh value overrides it where supported"
  end
end
