require "test_helper"

# The /deployments desk panel — what a human can actually READ off it.
#
# The ask behind this panel was "let me SEE what the desks are", so these assert the
# JUDGEMENTS the panel is supposed to hand over, not that some markup exists: the four
# numbers, the safety sentence on every desk, the reason a finished desk was safe to take,
# and the loud strip for a desk that left without a teardown record.
class DeskPanelTest < ActionView::TestCase
  SHIP = "/Users/alex/projects/mcritchie-studio/.worktrees/_ship".freeze

  def render_panel
    render partial: "tasks/desk_panel", locals: { panel: Desks::Panel.build }
  end

  def registry(desks:, generated_at: Time.current.utc.iso8601, summary: {})
    {
      "generated_at" => generated_at,
      "capacity" => { "current" => 55, "used" => 25, "free" => 30, "physical_max" => 64 },
      "summary" => { "worktrees" => desks.size, "dirty_worktrees" => 3, "withheld" => 57 }.merge(summary),
      "worktrees" => desks
    }
  end

  def desk(path: SHIP, **overrides)
    {
      "label" => "mcritchie-studio/#{File.basename(path)}",
      "app" => "mcritchie-studio",
      "task" => File.basename(path),
      "worktree" => path,
      "branch" => "feat/#{File.basename(path)}",
      "head" => "be798149",
      "dirty" => false,
      "health" => "down",
      "app_port" => 3024,
      "redis_db" => 24,
      "cleanup_candidate" => false,
      "withheld_reason" => "a builder is live-claiming it",
      "cleanup_rationale" => nil
    }.merge(overrides)
  end

  # ---- [component] the four numbers ------------------------------------------------

  test "[component] the tiles answer how many desks and how many band slots are free" do
    DeskRecord.sync!(registry(desks: [desk, desk(path: "#{SHIP}-2")]))

    render_panel

    assert_equal "2", css_select("[data-test='desk-tile-desks'] .font-mono").first.text.strip
    free = css_select("[data-test='desk-tile-band']").first.text

    assert_includes free, "30"
    assert_includes free, "55", "the free count is meaningless without the band it is out of"
    assert_equal "3", css_select("[data-test='desk-tile-dirty'] .font-mono").first.text.strip
    assert_equal "57", css_select("[data-test='desk-tile-held'] .font-mono").first.text.strip
  end

  # A capacity number with no age on it is the kind of number people trust for a week.
  test "[component] the panel stamps the age of its answer and calls out a stale one" do
    DeskRecord.sync!(registry(desks: [desk], generated_at: 8.hours.ago.utc.iso8601))

    render_panel

    assert_includes css_select("[data-test='desk-panel-freshness']").first.text, "STALE"
  end

  # "No desks" and "nobody has told us about the desks" are different facts, and only one
  # of them is reassuring.
  test "[component] an unsynced board says so instead of rendering zeros" do
    render_panel

    assert_includes css_select("[data-test='desk-panel-empty']").first.text,
                    "No desk snapshot has reached the board yet"
    assert_empty css_select("[data-test='desk-panel-tiles']"),
                 "a row of zeros would read as a verdict about the desks"
  end

  # ---- [component] the safety argument ----------------------------------------------

  test "[component] every live desk carries why it is free or why it is held" do
    DeskRecord.sync!(registry(desks: [
                                desk(path: "#{SHIP}-held"),
                                desk(path: "#{SHIP}-free", "cleanup_candidate" => true,
                                     "withheld_reason" => nil,
                                     "cleanup_rationale" => "merged into origin/accepted, tree clean")
                              ]))

    render_panel
    accounts = css_select("[data-test='desk-safety']").map { |node| node.text.strip }

    assert_includes accounts, "withheld — a builder is live-claiming it"
    assert_includes accounts, "merged into origin/accepted, tree clean"
  end

  # THE CELL THE MARKDOWN LEDGER EXISTED TO CARRY. A finished desk is only auditable if
  # the record says why taking it was safe; losing that sentence is what made 98 stranded
  # rows matter.
  test "[component] a finished desk shows the date it went and why it was safe" do
    DeskRecord.file!(worktree_path: SHIP, status: "removed", resolved_on: Date.new(2026, 8, 18),
                     label: "mcritchie-studio/_ship",
                     reason: "Hidden worktree; branch `release` is clean and HEAD be798149 is contained in origin/accepted")
    # The desk is GONE, so it is absent from the snapshot that follows its teardown — which
    # is exactly the shape a real removal leaves behind (run_snapshot fires at the end of
    # every `remove`), and it must not read as a desk that vanished unrecorded.
    DeskRecord.sync!(registry(desks: []))

    render_panel

    assert_empty css_select("[data-test='desk-panel-vanished']"),
                 "a RESOLVED episode is history, not an open record that went missing"
    row = css_select("[data-test='desk-removed-row']").first.text

    assert_includes row, "removed 2026-08-18"
    assert_includes css_select("[data-test='desk-removed-reason']").first.text, "contained in origin/accepted"
  end

  # ---- [component] the defect detector ----------------------------------------------

  test "[component] a desk that left without a teardown record is called out loudly" do
    DeskRecord.sync!(registry(desks: [desk]))
    DeskRecord.sync!(registry(desks: [], generated_at: 1.minute.from_now.utc.iso8601))

    render_panel
    strip = css_select("[data-test='desk-panel-vanished']").first

    assert strip, "an open record absent from the newest snapshot must never render as ordinary"
    assert_includes strip.text, "left without a teardown record"
    assert_includes strip.text, "_ship"
  end

  test "[component] no vanished strip when every open desk was seen" do
    DeskRecord.sync!(registry(desks: [desk]))

    render_panel

    assert_empty css_select("[data-test='desk-panel-vanished']")
  end

  # ---- [component] the cap tells the truth ------------------------------------------

  # The tile carries the TRUE total, so a capped list can never read as desks vanishing —
  # the same contract the board's capped Shipped column keeps.
  test "[component] a capped live list still reports the real total" do
    desks = (1..(Desks::Panel::LIVE_LIMIT + 3)).map { |i| desk(path: "#{SHIP}-#{i}") }
    DeskRecord.sync!(registry(desks: desks))

    render_panel

    assert_equal Desks::Panel::LIVE_LIMIT, css_select("[data-test='desk-live-row']").size
    assert_equal desks.size.to_s, css_select("[data-test='desk-tile-desks'] .font-mono").first.text.strip
    assert_includes css_select("[data-test='desk-live-truncated']").first.text, "+3 more"
  end

  # Dirty desks carry somebody's uncommitted work, so they are the desks a reader needs at
  # the top — not the ones that happen to sort first.
  test "[component] dirty desks lead the live list" do
    desks = (1..Desks::Panel::LIVE_LIMIT).map { |i| desk(path: "#{SHIP}-#{i}") }
    desks << desk(path: "#{SHIP}-zz-dirty", "dirty" => true)
    DeskRecord.sync!(registry(desks: desks))

    render_panel

    assert_includes css_select("[data-test='desk-live-row']").first.text, "zz-dirty"
  end
end
