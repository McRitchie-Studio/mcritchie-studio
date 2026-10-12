# frozen_string_literal: true

require "test_helper"

# [component] The kit export through the routes (task kit-export-and-clear-lens): /logos/:brand/kit.zip and
# /logos/:brand/kit/<file>.svg, admin only, always the current kit choice, and the brand page's Download kit button.
class LogosKitExportTest < ActionDispatch::IntegrationTest
  setup { @admin = users(:alex) }

  def entries(bytes) = ZipKit::FileReader.read_zip_structure(io: StringIO.new(bytes)).map(&:filename)
  def save_navbar = BrandKit.for("welding_v2").save_choice(:navbar, { rule: "4", text: "homogeneous", colouring: "original" }, by: @admin.email)

  test "a visitor and a non-admin are turned away like every other logo page, the .zip and .svg endings included" do
    [nil, users(:viewer)].each do |user|
      log_in_as(user) if user
      [brand_kit_export_path("welding_v2"), brand_kit_file_path("welding_v2", "navbar-dark.svg")].each do |path|
        get path
        assert_response :redirect, path
        assert_no_match(/<svg|PK/, response.body.to_s, path)
      end
    end
  end

  test "the zip is the saved kit, with a README" do
    log_in_as(@admin)
    save_navbar
    get brand_kit_export_path("welding_v2")
    assert_response :success
    assert_equal "application/zip", response.media_type
    assert_match(/attachment; filename="welding_v2-kit.zip"/, response.headers["Content-Disposition"])
    assert_equal ["welding_v2-kit/README.md", *BrandKitExport::FILES.keys.map { |name| "welding_v2-kit/#{name}" }], entries(response.body)
  end

  test "a kit file is always the current kit choice, inline or as a download" do
    log_in_as(@admin)
    get brand_kit_file_path("welding_v2", "navbar-dark.svg")
    before = response.body
    assert_equal BrandKit.for("welding_v2").variant(:navbar, tone: :dark).svg, before, "nothing saved: the Kit card's default"

    save_navbar
    get brand_kit_file_path("welding_v2", "navbar-dark.svg")
    assert_response :success
    assert_equal "image/svg+xml", response.media_type
    assert_equal BrandKit.find_by!(brand: "welding_v2").variant(:navbar, tone: :dark).svg, response.body
    refute_equal before, response.body, "the same URL now serves the saved choice"
    assert_match(/\Ainline; filename="welding_v2-navbar-dark.svg"/, response.headers["Content-Disposition"])
    get brand_kit_file_path("welding_v2", "navbar-dark.svg", download: 1)
    assert_match(/\Aattachment; filename="welding_v2-navbar-dark.svg"/, response.headers["Content-Disposition"])
    get navbar_logo_path("welding_v2", tone: "dark")
    assert_equal BrandKit.find_by!(brand: "welding_v2").variant(:navbar, tone: :dark).svg, response.body, "the plain route agrees with the kit file"
  end

  test "an unknown file or brand is a 404" do
    log_in_as(@admin)
    get brand_kit_file_path("welding_v2", "navbar-sepia.svg")
    assert_response :not_found
    get brand_kit_file_path("welding_v2", "README.md")
    assert_response :not_found
    get brand_kit_export_path("acme")
    assert_response :not_found
  end

  test "every brand page tab carries the Download kit button" do
    log_in_as(@admin)
    [{}, { type: "icon" }, { type: "stacked" }].each do |params|
      get logo_brand_path("welding_v2", params)
      assert_select "a[data-test='kit-download'][href=?][data-turbo='false']", brand_kit_export_path("welding_v2"), 1, params.inspect
    end
  end
end
