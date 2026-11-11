# frozen_string_literal: true

require "test_helper"
require "zip"
require_relative "../support/marketing_kit_fixtures"

# [integration] bin/sheet's halves across their boundaries: SheetPublisher against
# an in-memory Drive and Sheets (create, share, guarded replace, checkboxes, the
# API being off, dry run), and the drawer (python, openpyxl) drawing a recipe's
# age_bands and stamp column into the .xlsx Drive converts.
class MarketingKitSheetPublisherTest < ActiveSupport::TestCase
  include MarketingKitFixtures

  LOGO = Rails.root.join("test/fixtures/files/magic-banner.png").to_s
  SUBJECT = "team@mcritchie.studio"

  class FakeDrive
    Node = Struct.new(:id, :name, :mime_type, :parents, :body, :editor, keyword_init: true)
    Perm = Struct.new(:email_address)
    attr_reader :nodes, :writes, :perms

    def initialize = (@nodes, @writes, @perms = [], [], Hash.new { |h, k| h[k] = [] })

    def paged(query:)
      if (m = query.match(/\A'(.+)' in parents and name = '(.+)' and trashed = false\z/))
        nodes.select { |n| n.parents.include?(m[1]) && n.name == m[2] }
      elsif (m = query.match(/\Aname = '(.+)' and mimeType = '(.+)' and trashed = false\z/))
        nodes.select { |n| n.name == m[1] && n.mime_type == m[2] }
      else
        raise "unexpected query #{query}"
      end
    end

    def files_create(name:, parents:, mime_type: nil, body: nil, content_type: nil)
      @writes << [:create, name]
      Node.new(id: "id#{nodes.size}", name: name, mime_type: mime_type, parents: parents, body: body, editor: SUBJECT).tap { |n| nodes << n }
    end

    def files_update(id, body: nil, content_type: nil)
      @writes << [:update, id]
      nodes.find { |n| n.id == id }.body = body
    end

    def permissions_list(id) = Struct.new(:permissions).new(perms[id].map { |e| Perm.new(e) })

    def permissions_create(id, email:, role: "writer")
      @writes << [:share, email]
      perms[id] << email
    end

    def service = self

    def get_file(id, fields:)
      editor = nodes.find { |n| n.id == id }.editor
      Struct.new(:last_modifying_user).new(Struct.new(:email_address).new(editor))
    end
  end

  class FakeSheets
    attr_reader :batches
    attr_accessor :off

    def initialize = @batches = []
    def sheet_id(_id, title) = { "Cards" => 0, "Overview" => 1 }.fetch(title)

    def batch_update(id, requests)
      raise Workspace::SheetsClient::Disabled, "the Google Sheets API is off" if off

      batches << [id, requests]
    end
  end

  def with_recipe
    with_kit do |kit|
      dir = File.dirname(kit)
      FileUtils.cp(LOGO, File.join(dir, "logos/png/icon_light.png"))
      recipe = {
        "kit" => "kit.yml", "title" => "Test Cards", "sheet_title" => "Cards", "sections" => %w[Card Terms Rewards],
        "columns" => [
          { "key" => "card", "head" => "Card", "kind" => "item", "width" => 28, "section" => 0 },
          { "key" => "limit", "head" => "Limit", "kind" => "money", "width" => 12, "section" => 1 },
          { "key" => "used", "head" => "Used", "kind" => "stamp", "width" => 8, "section" => 1, "target" => "Last Used" },
          { "key" => "last_used", "head" => "Last Used", "kind" => "date", "width" => 11, "section" => 1, "format" => "m/yy",
            "age_bands" => { "months" => [4, 10, 16], "fresh" => ["💳"] } },
          { "key" => "archived", "head" => "Archived", "kind" => "archive", "width" => 11, "section" => 2 }
        ],
        "rows" => [["One", 100, nil, "2026-10-01", ""], ["Two", 50, nil, "💳", "Archived"]],
        "variables" => [{ "label" => "Total", "value" => '=SUMIFS({col:limit}{first}:{col:limit}{last},{col:archived}{first}:{col:archived}{last},"<>Archived")', "kind" => "money", "emphasis" => true }],
        "statuses" => [],
        "drive" => { "subject" => SUBJECT, "folder" => "McRitchie Studio Records" }
      }
      File.write(File.join(dir, "recipe.yml"), recipe.to_yaml)
      r = MarketingKit::SheetRecipe.load(File.join(dir, "recipe.yml"))
      xlsx = File.join(dir, "out.xlsx")
      MarketingKit::Office.new(r.spec).write_sheet_payload(r.payload, xlsx)
      yield r, xlsx
    end
  end

  def publish(r, xlsx, drive, sheets, **opts) = MarketingKit::SheetPublisher.new(r, xlsx: xlsx, drive: drive, sheets: sheets, **opts).run

  test "a first publish makes the folder and the sheet, shares both, and ticks the stamp column into checkboxes" do
    with_recipe do |r, xlsx|
      drive, sheets = FakeDrive.new, FakeSheets.new
      pub = publish(r, xlsx, drive, sheets)
      assert_equal [[:create, "McRitchie Studio Records"], [:share, "alex@mcritchie.studio"], [:create, "Test Cards"],
                    [:share, "alex@mcritchie.studio"]], drive.writes, "a Studio subject's admin is alex@mcritchie.studio: one share each"
      id, requests = sheets.batches.sole
      assert_equal pub.sheet_id, id
      range = requests.sole.dig(:setDataValidation, :range)
      assert_equal [0, 8, 999, 4, 5], range.values_at(:sheetId, :startRowIndex, :endRowIndex, :startColumnIndex, :endColumnIndex)
      assert_match %r{\Ahttps://docs.google.com/spreadsheets/d/id\d+/edit\z}, pub.url
    end
  end

  test "an MI recipe shares with MI's admin and alex@mcritchie.studio" do
    with_recipe do |r, xlsx|
      r.data[:drive][:subject] = "team@mcritchie.industries"
      assert_equal %w[alex@mcritchie.industries alex@mcritchie.studio], MarketingKit::SheetPublisher.new(r, xlsx: xlsx, drive: FakeDrive.new, sheets: FakeSheets.new).share_with
    end
  end

  test "a replace goes in place when the account itself edited last, and stops when a person did" do
    with_recipe do |r, xlsx|
      drive, sheets = FakeDrive.new, FakeSheets.new
      first = publish(r, xlsx, drive, sheets).sheet_id
      drive.writes.clear

      again = publish(r, xlsx, drive, sheets)
      assert_equal first, again.sheet_id, "same file, same link"
      assert_equal [[:update, first]], drive.writes

      drive.nodes.find { |n| n.id == first }.editor = "alex@mcritchie.studio"
      drive.writes.clear
      err = assert_raises(MarketingKit::SheetPublisher::Edited) { publish(r, xlsx, drive, sheets) }
      assert_match(/last edited by alex@mcritchie.studio/, err.message)
      assert_empty drive.writes, "a person's edits are never overwritten"

      publish(r, xlsx, drive, sheets, force: true)
      assert_equal [[:update, first]], drive.writes, "--force replaces once their edits are carried over"

      drive.nodes.find { |n| n.id == first }.editor = nil
      drive.writes.clear
      err = assert_raises(MarketingKit::SheetPublisher::Edited) { publish(r, xlsx, drive, sheets) }
      assert_match(/an unknown user/, err.message)
      assert_empty drive.writes, "an editor Drive does not name is never assumed to be the account"
    end
  end

  test "with the Sheets API off the sheet still publishes and says the checkboxes were skipped" do
    with_recipe do |r, xlsx|
      sheets = FakeSheets.new.tap { |s| s.off = true }
      pub = publish(r, xlsx, FakeDrive.new, sheets)
      assert pub.sheet_id
      assert_match(/checkboxes: the Google Sheets API is off/, pub.results.find { |x| x.action == :skipped }.detail)
    end
  end

  test "a dry run reports and writes nothing" do
    with_recipe do |r, xlsx|
      drive, sheets = FakeDrive.new, FakeSheets.new
      pub = publish(r, xlsx, drive, sheets, dry_run: true)
      assert_empty drive.writes
      assert_empty sheets.batches
      assert_equal %i[create create], pub.results.map(&:action)
    end
  end

  test "the drawer cuts the age-banded column out of the row colours, so its own rules win" do
    with_recipe do |_r, xlsx|
      sheet = Zip::File.open(xlsx) { |z| z.find_entry("xl/worksheets/sheet1.xml").get_input_stream.read.force_encoding("UTF-8") }
      # B item, C gutter, D limit, E used (stamp), F last used (age_bands), G archived.
      ranges = sheet.scan(/<conditionalFormatting sqref="([^"]+)">/).flatten
      assert_includes ranges, "B9:E999 G9:G999", "row bands skip column F"
      assert_includes ranges, "F9:F999", "column F carries its own rules"
      refute(ranges.any? { |s| s.include?("B9:G999") }, "no range overlaps the dated column")
      f_rules = sheet[%r{<conditionalFormatting sqref="F9:F999">(.*?)</conditionalFormatting>}m, 1]
      assert_includes f_rules, %($G9="Archived"), "archived greys the dated cell first"
      assert_includes f_rules, "EDATE(TODAY(),-16)"
      assert_match(/\$F9="(💳|&#128179;)"/, sheet, "a fresh marker counts as recent")
      assert_match(/<c r="E9"[^>]*s="\d+"/, sheet, "the stamp column is drawn, empty, for the checkboxes")
    end
  end
end
