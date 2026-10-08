# frozen_string_literal: true

require "test_helper"

# The guard catalog is the record of what became of each guard Alex ruled on. A
# DELETE or BY CONSTRUCTION row with no mark reads as applied when nobody has
# said so, which is the wrong decision waiting to be made. So every such row
# opens its Mark cell with one of the page's marks. This is a property of the
# page's own tables, not a copy of any code, so it stays a test.
#
# A KEEP row needs nothing and is not checked.
class GuardCatalogMarksTest < ActiveSupport::TestCase
  CATALOG = Rails.root.join("docs", "agents", "system", "guard-catalog.md")

  # The verdict columns, by table: the group tables say Disposition, the ten
  # decisions say Decision.
  VERDICT_HEADERS = %w[Disposition Decision].freeze
  RULED = /\A(?:DELETE|BY CONSTRUCTION)\b/
  # Longest first: "applied in part" must not read as "applied".
  MARKS = ["applied in part", "applied", "kept against the verdict", "awaiting build", "awaiting Alex"].freeze
  MARK = /\A(#{MARKS.map { |mark| Regexp.escape(mark) }.join("|")}): \S/
  # These marks name the task that did, or will do, the work.
  NAMES_A_TASK = ["applied in part", "applied", "awaiting build"].freeze
  TASK_SLUG = /`[a-z0-9]+(?:-[a-z0-9]+)+`/

  Row = Struct.new(:line, :guard, :verdict, :mark)

  # Every table row under a header that carries a verdict column. A table with a
  # verdict column and no Mark column yields rows whose mark is nil.
  def ruled_rows(text)
    rows = []
    header = nil
    text.each_line.with_index(1) do |line, number|
      unless line.start_with?("|")
        header = nil
        next
      end
      cells = line.strip.delete_prefix("|").delete_suffix("|").split(" | ").map(&:strip)
      if header.nil?
        header = cells
        next
      end
      next if cells.all? { |cell| cell.match?(/\A-+\z/) }

      verdict_at = header.index { |name| VERDICT_HEADERS.include?(name) }
      next unless verdict_at && cells[verdict_at].to_s.match?(RULED)

      mark_at = header.index("Mark")
      mark = mark_at && cells.size == header.size ? cells[mark_at] : nil
      rows << Row.new(number, cells.first, cells[verdict_at], mark)
    end
    rows
  end

  # Why a row's mark does not stand, or nil when it does.
  def mark_defect(row)
    return "has no Mark cell (a missing column, or a stray pipe in the row)" if row.mark.nil?

    word = row.mark[MARK, 1]
    return "opens its Mark cell with none of: #{MARKS.join(", ")}" unless word
    return "is marked #{word} and names no task slug" if NAMES_A_TASK.include?(word) && !row.mark.match?(TASK_SLUG)

    nil
  end

  def defects(text)
    ruled_rows(text).filter_map do |row|
      defect = mark_defect(row)
      "line #{row.line} (#{row.guard[0, 60]}) #{defect}" if defect
    end
  end

  test "[static] every delete and construction row is marked" do
    text = File.read(CATALOG)
    rows = ruled_rows(text)

    # The census is real: ten group tables and the ten decisions, not an empty scan.
    assert_operator rows.size, :>=, 50, "the scan found #{rows.size} DELETE and BY CONSTRUCTION rows; the tables moved"
    assert_equal 10, text.scan(/^\| Guard \| .*\| Disposition \| Mark \|$/).size,
                 "each of the ten group tables carries a Disposition column and a Mark column"

    found = defects(text)
    assert_empty found, "guard-catalog.md rows without a standing mark:\n  #{found.join("\n  ")}\n" \
                        "Open the Mark cell with one of: #{MARKS.join(", ")}."
  end

  # The control: blank one mark on the real page and the scan names that row.
  test "[static] a blanked mark is caught on the row that lost it" do
    text = File.read(CATALOG)
    victim = ruled_rows(text).find { |row| row.mark.to_s.start_with?("applied: ") }
    assert victim, "the page has an applied row to blank"

    lines = text.lines
    original = lines[victim.line - 1]
    lines[victim.line - 1] = original.sub(/ \| #{Regexp.escape(victim.mark)} \|\s*\z/) { " |  |\n" }
    assert_not_equal original, lines[victim.line - 1], "the control must change the row"

    found = defects(lines.join)
    assert_equal 1, found.size, "exactly the blanked row is reported: #{found.inspect}"
    assert_includes found.first, "line #{victim.line} "
  end

  test "[static] an unknown mark, a mark with no task and a markless table are each caught" do
    table = lambda do |mark_header, mark|
      "| Guard | n | Disposition |#{mark_header}\n|---|---|---|#{"---|" if mark_header.present?}\n" \
        "| `bin/x` | 1 | DELETE: gone |#{mark}\n"
    end

    assert_match(/opens its Mark cell with none of/, defects(table.call(" Mark |", " done |")).first)
    assert_match(/names no task slug/, defects(table.call(" Mark |", " applied: yes |")).first)
    assert_match(/has no Mark cell/, defects(table.call("", "")).first)
    assert_empty defects(table.call(" Mark |", " applied in part: `some-task` (half); kept: the rest |"))
    assert_empty defects(table.call(" Mark |", " awaiting Alex: no task names this row |"))
    assert_empty defects("| Guard | n | Disposition | Mark |\n|---|---|---|---|\n| `bin/x` | 1 | KEEP |  |\n"),
                 "a KEEP row needs nothing"
  end
end
