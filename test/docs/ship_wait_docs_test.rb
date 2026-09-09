# frozen_string_literal: true

require "test_helper"

# Tripwire for the sentence that used to stop halfway (task
# ship-wait-has-no-primitive, 2026-09-09).
#
# Four docs told the builder to run `bin/ship` in the BACKGROUND and then said
# nothing about how to WAIT for it. That silence is not neutral: five builders in
# one session each filled it with the same watcher, `while pgrep -f "bin/ship
# <slug>"`, which can never fire once a sibling shell carries the pattern. So the
# rule these tests hold is narrow and mechanical — **wherever a doc says "run it
# in the background", the command to wait must be within reach on the same
# page.** Delete `bin/ship-wait` from any of them and this file goes red.
#
# NOTE FOR THE RUNNER: `bin/fast-check` cannot see `test/docs` (its diff→test map
# does not reach this directory), so this lane must be run explicitly:
#   bin/rails test test/docs/ship_wait_docs_test.rb
class ShipWaitDocsTest < ActiveSupport::TestCase
  AGENTS = Rails.root.join("docs", "agents")

  # The four places the "run it in the background" advice lives. claude.md and
  # index.md are the SOURCES of the generated projects-root CLAUDE.md / AGENTS.md
  # — editing the roots directly is what drifts them.
  BACKGROUND_DOCS = [
    "claude.md",
    "index.md",
    "modules/building-sop.md",
    "modules/devops-task-board.md"
  ].freeze

  # Markdown-emphasis-insensitive read (the house pattern, mirrors
  # ship_docs_sync_docs_test.rb): drop * and ` and collapse whitespace, so a
  # line-wrapped phrase matches as one run.
  def norm(rel)
    File.read(AGENTS.join(rel)).gsub(/[*`]/, "").gsub(/\s+/, " ")
  end

  test "[static] every doc that says run it in the background names bin/ship-wait" do
    BACKGROUND_DOCS.each do |rel|
      body = norm(rel)
      assert_match(/run it in the background/i, body,
        "#{rel} is listed here because it carries the background advice")
      assert_match(/run it in the background[^.]{0,160}bin\/ship-wait/im, body,
        "#{rel} must end the background sentence with the command, not stop at the advice")
    end
  end

  test "[static] every one of those docs shows a runnable ship-wait invocation" do
    BACKGROUND_DOCS.each do |rel|
      assert_match(/bin\/ship-wait <task-slug> --launch/, norm(rel),
        "#{rel} must show the copy-pasteable form, not merely mention the script")
    end
  end

  test "[static] the docs warn off the hand-rolled pgrep watcher" do
    (BACKGROUND_DOCS - ["claude.md", "index.md"]).each do |rel|
      body = norm(rel)
      assert_match(/pgrep/, body, "#{rel} must name the watcher nobody should write")
      assert_match(/sibling/i, body,
        "#{rel} must say WHY it cannot fire — a sibling shell carries the same pattern")
    end
    # The two generated roots carry the short form; they must still say "do not".
    ["claude.md", "index.md"].each do |rel|
      assert_match(/do not hand-roll a pgrep watcher/i, norm(rel),
        "#{rel} must warn off the reinvention even in its condensed form")
    end
  end

  test "[static] the canonical section documents the exit codes the caller branches on" do
    body = norm("modules/devops-task-board.md")
    assert_match(/bin\/ship-wait/, body)
    { "0" => /SUCCEEDED/, "1" => /FAILED/, "2" => /TIMEOUT/, "3" => /USAGE/, "4" => /NO LOG/ }.each do |code, label|
      assert_match(/\| #{code} \|[^|]*#{label}/, body,
        "the exit-code table must carry #{code} → #{label.source}; the caller branches on it")
    end
  end

  test "[static] the canonical section states the two properties that make it fire" do
    body = norm("modules/devops-task-board.md")
    assert_match(/never matches itself/i, body, "the self-match rule is the whole design")
    assert_match(/Already-done returns AT ONCE/i, body,
      "the already-finished fast path is the case the naive loop gets most wrong")
    assert_match(/stage: submitted \(read back verified\)/, body,
      "the doc names the authoritative log line, so a reader can check it by hand")
    assert_match(/exit 0 on a run that never reached the seam/i, body,
      "the doc says why an exit code is not a verdict")
  end

  test "[static] the primitive's own source carries no process-table pattern" do
    # The doc claims this; the claim is checked here too so the doc cannot go
    # stale against the code it describes.
    %w[bin/ship-wait bin/lib/ship_wait.rb].each do |rel|
      code = File.read(Rails.root.join(rel)).each_line.reject { |l| l.strip.start_with?("#") }.join
      refute_match(/\bpgrep\b|\bpkill\b/, code, "#{rel} must never read the process table by pattern")
    end
  end
end
