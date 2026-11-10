# frozen_string_literal: true

require "test_helper"
require "zip"
require_relative "../support/marketing_kit_fixtures"

# [integration] The Sheet template across its two boundaries: Build puts it in
# 05 Templates as a Google Sheet, and office.py (Python, openpyxl) writes the
# .xlsx Drive converts. The workbook is read back from its XML, the way Drive
# reads it: title in A1 and the logo under it, freeze under the head and right of column A, no merged cells, the
# head fills the payload chose, the logo drawing, and the How to use tab.
class MarketingKitSheetTemplateBuildTest < ActiveSupport::TestCase
  include MarketingKitFixtures

  LOGO = Rails.root.join("test/fixtures/files/magic-banner.png").to_s

  test "office.py writes a frozen, unmerged, branded workbook" do
    load_kit do |spec|
      FileUtils.cp(LOGO, spec.logo_png(:horizontal, :light))
      Dir.mktmpdir do |out|
        path = MarketingKit::Office.new(spec).write_sheet(File.join(out, "sheet.xlsx"))
        xml = Zip::File.open(path) { |z| z.entries.to_h { |e| [e.name, e.get_input_stream.read] } }
        sheet = xml.fetch("xl/worksheets/sheet1.xml")

        assert_match(/<pane [^>]*xSplit="1"[^>]*ySplit="6"[^>]*topLeftCell="B7"[^>]*state="frozen"/, sheet)
        assert_no_match(/<mergeCell/, sheet, "the template never merges a cell")
        assert_match(/showGridLines="0"/, sheet)
        assert_match(/<autoFilter ref="A6:I10"/, sheet)
        assert_match(/<dataValidation [^>]*type="list"/, sheet)
        assert_includes sheet, %(IF(G7="",$B$3,G7)), "the formula reads the Default rate variable"

        styles = xml.fetch("xl/styles.xml")
        MarketingKit::SheetTemplate.new(spec).sections.each do |s|
          [s.top, s.low].each { |hex| assert_match(/rgb="\h\h#{hex.delete('#')}"/, styles, "head fill #{hex}") }
        end
        assert_match(%r{<c r="A1"[^>]*><is><t>\[Sheet Title\]</t>}, sheet, "the title is in A1")
        assert_match(%r{<c r="B2"[^>]*><is><t>DEFAULT RATE</t>}, sheet, "variables start in B; A2-A3 hold the logo")
        assert_no_match(/<c r="A2"/, sheet)
        drawing = xml.fetch("xl/drawings/drawing1.xml")
        assert_match(%r{<from><col>0</col><colOff>\d+</colOff><row>1</row>}, drawing, "the logo is anchored in A2")
        assert(xml.keys.any? { |k| k.start_with?("xl/media/") }, "the logo is embedded")
        assert_includes xml.fetch("xl/workbook.xml"), 'name="How to use"'
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
