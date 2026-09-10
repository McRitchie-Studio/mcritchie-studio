# frozen_string_literal: true

require "test_helper"

# A DOC MUST NOT PRESCRIBE A HUB-ONLY SCRIPT THROUGH THE DESK'S OWN bin/.
#
# MEASURED 2026-09-10 (task handoff-narration-overclaims-four). The canonical handoff
# block in devops-task-board.md prescribed `<desk>/bin/ship <task-slug>`. A hub desk
# carries bin/ship, so it works there; a turf-monster or rolio desk carries none, so a
# builder pasting it got `No such file or directory` — the exact failure the change that
# wrote it existed to kill. Nothing caught it: the entry-doc guard
# (test/docs/fast_lane_hub_path_docs_test.rb) reads only claude.md and index.md, and its
# BARE pattern exempts any `/`-prefixed form by design, so `<desk>/bin/ship` passes it.
#
# The rule here is narrower than that guard and complementary to it: in ANY fenced block
# under docs/, a desk-placeholder path (`<desk>/bin/…`, `<worktree>/bin/…`) must not name
# a script that lives in the hub alone. Name the absolute path begin prints instead.
class DeskRelativeHubScriptDocsTest < ActiveSupport::TestCase
  ROOT = File.expand_path("../..", __dir__)

  # Scripts only the hub carries. Each must really be an executable in THIS repo's bin/
  # (asserted below), so the list cannot drift into naming phantoms.
  HUB_ONLY = %w[ship ship-wait fast-check full-suite-check dor-check task].freeze

  # Longest-first so `ship` never shadows `ship-wait` in the alternation.
  DESK_BIN = %r{<(?:desk|worktree)>/bin/(#{Regexp.union(HUB_ONLY.sort_by { |s| -s.size })})(?![\w-])}

  def self.fenced_lines
    Dir.glob(File.join(ROOT, "docs", "**", "*.md")).sort.flat_map do |path|
      rel = path.delete_prefix("#{ROOT}/")
      inside = false
      File.readlines(path, chomp: true).each_with_index.filter_map do |line, idx|
        if line.lstrip.start_with?("```")
          inside = !inside
          next
        end
        [rel, idx + 1, line] if inside
      end
    end
  end

  test "[docs] no fenced block routes a hub-only script through the desk's bin" do
    lines = self.class.fenced_lines
    assert_operator lines.size, :>, 500, "the fence scan read almost nothing — it is broken"

    offences = lines.filter_map do |rel, number, line|
      hit = line.match(DESK_BIN) or next
      "#{rel}:#{number} prescribes #{hit[0]} — a satellite desk has no bin/#{hit[1]}. " \
        "Name the absolute path `bin/task begin` prints (write it as `<ship>`)."
    end
    assert_empty offences, offences.join("\n")
  end

  test "[docs] the canonical handoff block names the printed path, not the desk's bin" do
    body = File.read(File.join(ROOT, "docs/agents/modules/devops-task-board.md"))
    assert_includes body, "<ship> <task-slug>",
                    "the handoff block no longer uses the <ship> placeholder — re-check it by hand"
  end

  test "[unit] the pattern bites the measured form and spares the absolute one" do
    assert_match DESK_BIN, "<desk>/bin/ship <task-slug>"
    assert_match DESK_BIN, "<worktree>/bin/fast-check <task-slug>"
    assert_equal "ship-wait", "<desk>/bin/ship-wait x".match(DESK_BIN)[1], "ship shadowed ship-wait"
    refute_match DESK_BIN, "/Users/alex/projects/mcritchie-studio/bin/ship <task-slug>"
    refute_match DESK_BIN, "<desk>/bin/rails test"
  end

  test "[unit] every hub-only script named is a real executable in the hub" do
    HUB_ONLY.each do |script|
      assert File.executable?(File.join(ROOT, "bin", script)), "bin/#{script} is not an executable here"
    end
  end
end
