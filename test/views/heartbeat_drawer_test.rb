require "test_helper"

# [component] the per-ACTION grading drawer body (heartbeat/drawer) — the drill-down
# shown when the operator clicks a raw tool-call row. Beyond the summary + grade
# editors, it renders the action's full INPUT and OUTPUT panes. Those payloads are
# stored as raw (often escaped) JSON strings; this asserts they render pretty-printed
# (2-space indent + real newlines) when parseable, and untouched when they are not.
class HeartbeatDrawerTest < ActionView::TestCase
  def action(**attrs)
    AgentAction.create!({ session_id: "d", kind: "read_file", outcome: "ok", actor: "agent",
                           seq: 0, occurred_at: Time.current }.merge(attrs))
  end

  test "[component] the drawer pretty-prints a JSON input with indent and real newlines" do
    a = action(
      input: %({"type":"text","file":{"path":"a.rb","content":"alpha\\nbeta"}})
    )

    render partial: "heartbeat/drawer", locals: { action: a, alex: nil, mcr: nil }

    pane = css_select("pre[data-test=drawer-input]").first
    assert pane, "the input pane must render"
    text = pane.text
    # structure expanded across lines with a 2-space indent (not the raw one-liner)
    assert_includes text, %(  "type": "text")
    # the escaped newline inside the file content is now a REAL line break
    assert_includes text, "alpha\nbeta"
    refute_includes text, "alpha\\nbeta", "the escaped \\n must be unescaped for readability"
  end

  test "[component] the drawer renders a non-JSON output untouched (never mangled)" do
    a = action(output: "git push origin feat/x && echo done")

    render partial: "heartbeat/drawer", locals: { action: a, alex: nil, mcr: nil }

    pane = css_select("pre[data-test=drawer-output]").first
    assert pane, "the output pane must render"
    assert_equal "git push origin feat/x && echo done", pane.text.strip
  end
end
