# frozen_string_literal: true

require "test_helper"
require "zip"
require_relative "../support/marketing_kit_fixtures"

# [integration] The Sheet template across its two boundaries: Build puts it in
# 05 Templates as a Google Sheet, and office.py (Python, openpyxl) writes the
# .xlsx Drive converts. The workbook is read back from its XML, the way Drive
# reads it: margins on row 1 and column A, the icon in A2, the title in B2, the
# freeze at C7 (under the head, right of the item column), no merged cells, the
# head fills the payload chose, the logo drawing, and the How to use tab.
class MarketingKitSheetTemplateBuildTest < ActiveSupport::TestCase
  include MarketingKitFixtures

  LOGO = Rails.root.join("test/fixtures/files/magic-banner.png").to_s

  test "office.py writes a frozen, unmerged, branded workbook" do
    load_kit do |spec|
      FileUtils.cp(LOGO, spec.logo_png(:icon, :light))
      Dir.mktmpdir do |out|
        path = MarketingKit::Office.new(spec).write_sheet(File.join(out, "sheet.xlsx"))
        xml = Zip::File.open(path) { |z| z.entries.to_h { |e| [e.name, e.get_input_stream.read] } }
        sheet = xml.fetch("xl/worksheets/sheet1.xml")

        assert_match(/<pane [^>]*xSplit="2"[^>]*ySplit="7"[^>]*topLeftCell="C8"[^>]*state="frozen"/, sheet)
        assert_no_match(/<mergeCell/, sheet, "the template never merges a cell")
        assert_match(/showGridLines="0"/, sheet)
        assert_match(/<autoFilter ref="B7:K11"/, sheet)
        assert_match(/<dataValidation [^>]*type="list"/, sheet)
        assert_includes sheet, %(IF(I8="",$E$4,I8)), "the formula reads the Default rate variable"

        styles = xml.fetch("xl/styles.xml")
        MarketingKit::SheetTemplate.new(spec).sections.each do |s|
          [s.top, s.low].each { |hex| assert_match(/rgb="\h\h#{hex.delete('#')}"/, styles, "head fill #{hex}") }
        end
        assert_match(%r{<c r="B2"[^>]*><is><t>\[Sheet Title\]</t>}, sheet, "the title is in B2")
        assert_no_match(/<c r="[C-Z]2"/, sheet, "row 2 is the title alone, so it can run across the row")
        assert_match(%r{<c r="B3"[^>]*><is><t>Last Updated: \w{3} \d+(st|nd|rd|th), \d{4}</t>}, sheet, "the build stamps Last Updated under the title")
        assert_match(%r{<c r="D3"[^>]*><is><t>TOTAL AMOUNT</t>}, sheet, "the headline variable leads from D3, past the gutter")
        assert_match(%r{<col width="2.57"[^>]*min="3" max="3"/>}, sheet, "column C is a narrow gutter")
        assert_no_match(/<c r="C\d+"[^>]*><(is|f|v)>/, sheet, "the gutter holds no value")
        assert_match(%r{<c r="D4"[^>]*><f>SUM\(G8:G998\)</f>}, sheet, "Total amount sums the Amount column")
        assert_match(/<row r="4" ht="26"/, sheet, "the headline row is tall enough for it")
        assert_match(%r{<c r="B8"[^>]*><is><t>\[Example item one\]</t>}, sheet, "the table starts in column B")
        assert_no_match(/<c r="A\d+"/, sheet, "column A is a margin: no cell in it carries anything")
        assert_no_match(/<c r="[A-Z]+1"/, sheet, "row 1 is a margin")
        drawing = xml.fetch("xl/drawings/drawing1.xml")
        assert_match(%r{<from><col>0</col><colOff>\d+</colOff><row>1</row>}, drawing, "the icon is anchored in A2")
        assert(xml.keys.any? { |k| k.start_with?("xl/media/") }, "the logo is embedded")
        assert_includes xml.fetch("xl/workbook.xml"), 'name="How to use"'
      end
    end
  end

  test "an emphasised variable draws larger, in the title colour, on a taller row" do
    load_kit do |spec|
      FileUtils.cp(LOGO, spec.logo_png(:icon, :light))
      Dir.mktmpdir do |out|
        office = MarketingKit::Office.new(spec)
        payload = MarketingKit::SheetTemplate.new(spec).payload
        payload[:variables] = [payload[:variables].last.merge(emphasis: true), payload[:variables].first]
        path = office.send(:draw, "sheet", payload, File.join(out, "emphasis.xlsx"))
        xml = Zip::File.open(path) { |z| z.entries.to_h { |e| [e.name, e.get_input_stream.read] } }
        assert_match(/<row r="4" ht="26"/, xml.fetch("xl/worksheets/sheet1.xml"))
        title = spec.colour(:title).delete("#") # the headline keeps the brand's title colour
        assert_match(%r{<font><name val="Montserrat"/><b val="1"/><color rgb="\h\h#{title}"/><sz val="16"/></font>}, xml.fetch("xl/styles.xml"))
      end
    end
  end

  test "a tall icon keeps its proportions and sits centred in A2" do
    load_kit do |spec|
      tall = File.join(Dir.mktmpdir, "tall.png")
      MarketingKit::Office.run!(MarketingKit::Office.python, "-c",
                                "from PIL import Image; Image.new('RGB', (100, 200), 'red').save('#{tall}')")
      FileUtils.cp(tall, spec.logo_png(:icon, :light))
      Dir.mktmpdir do |out|
        path = MarketingKit::Office.new(spec).write_sheet(File.join(out, "tall.xlsx"))
        xml = Zip::File.open(path) { |z| z.entries.to_h { |e| [e.name, e.get_input_stream.read] } }
        cx, cy = xml.fetch("xl/drawings/drawing1.xml").match(/<ext cx="(\d+)" cy="(\d+)"/).captures.map(&:to_i)
        assert_in_delta 0.5, cx.to_f / cy, 0.02, "drawn at its own 1:2 shape, not squashed square"
        col_off = xml.fetch("xl/drawings/drawing1.xml")[%r{<colOff>(\d+)</colOff>}, 1].to_i
        assert_operator col_off, :>, 4 * 9525, "a narrow icon is centred across A2, not pinned to its left edge"
        sheet = xml.fetch("xl/worksheets/sheet1.xml")
        title_style = sheet[%r{<c r="B2" s="(\d+)"}, 1].to_i
        xf = xml.fetch("xl/styles.xml").scan(%r{<xf [^>]*?(?:/>|>.*?</xf>)}m).drop(1)[title_style]
        assert_includes xf, 'vertical="center"', "the title is centred in row 2"
      end
    end
  end

  test "a column's choices draw a dropdown and its own format wins over its kind's" do
    load_kit do |spec|
      FileUtils.cp(LOGO, spec.logo_png(:icon, :light))
      Dir.mktmpdir do |out|
        payload = MarketingKit::SheetTemplate.new(spec).payload
        payload[:columns] = payload[:columns].map do |c|
          case c[:key]
          when "category" then c.merge(choices: %w[Alpha Beta])
          when "amount" then c.merge(format: '"$"#,##0')
          else c
          end
        end
        path = MarketingKit::Office.new(spec).send(:draw, "sheet", payload, File.join(out, "choices.xlsx"))
        xml = Zip::File.open(path) { |z| z.entries.to_h { |e| [e.name, e.get_input_stream.read] } }
        sheet = xml.fetch("xl/worksheets/sheet1.xml")
        assert_match(%r{<dataValidation sqref="D8:D998"[^>]*type="list"><formula1>"Alpha,Beta"</formula1>}, sheet)
        assert_match(%r{<dataValidation sqref="H8:H998"[^>]*type="list"><formula1>"Active,Paused,Closed"</formula1>}, sheet, "Status keeps the sheet's statuses")
        assert_includes xml.fetch("xl/styles.xml"), %(formatCode="&quot;$&quot;#,##0"/>)
      end
    end
  end

  test "a build files the Sheet template in 05 Templates as a Google Sheet" do
    load_kit do |spec|
      office = Class.new do
        def slides_name = "RF Template — Slides"
        %i[write_slides write_sheet].each { |m| define_method(m) { |path| File.write(path, "x") && path } }
        def write_tracker(_inventory, path) = File.write(path, "x") && path
      end.new
      MarketingKit::Office.stub(:new, office) do
        Dir.mktmpdir do |out|
          build = MarketingKit::Build.new(spec, out: out, pdf: false).run
          entry = build.entries.find { |e| e.name == "RF Template — Sheet" }
          assert entry, "the Sheet template is in the manifest"
          assert_equal [MarketingKit::Layout::TEMPLATES, "sheet", "Template"], [entry.folder, entry.kind, entry.type]
          assert File.file?(File.join(out, "templates", "RF Template — Sheet.xlsx"))
          tracker_rows = build.entries.map(&:name)
          assert_includes tracker_rows, "Marketing Kit Tracker"
        end
      end
    end
  end
end
