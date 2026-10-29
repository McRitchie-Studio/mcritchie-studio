# frozen_string_literal: true

require "test_helper"
require "rake"

# [unit] BrandKitInstall and `logos:install` (task studio-adopts-its-kit): a brand's saved kit written into an app's
# public/brand/, each file byte-equal to what /logos/:brand/kit/<file> serves, and a second install a no-op.
class BrandKitInstallTest < ActiveSupport::TestCase
  # The studio kit Alex McRitchie saved on production, 2026-10-14 05:25Z: the hub's own branding is drawn from it.
  STUDIO_NAVBAR = { "rule" => 4, "text" => "second", "edits" => { "first_weight" => "800", "ending_colour" => "8E82FE" }, "colouring" => "alt" }.freeze
  STUDIO_STACKED = { "form" => "two_line", "text" => "first", "edits" => { "ending_colour" => "8E82FE", "ending_weight" => "800" }, "colouring" => "alt" }.freeze

  setup { @dir = Pathname(Dir.mktmpdir("brand-kit-install")) }
  teardown { FileUtils.rm_rf(@dir) }

  def studio_kit
    BrandKit.create!(brand: "studio", navbar_choice: STUDIO_NAVBAR, stacked_choice: STUDIO_STACKED, updated_by: "alex@test.com")
  end

  test "writes every kit file byte-equal to the export, and the manifest" do
    kit = studio_kit
    result = BrandKitInstall.new(kit, dest: @dir).call

    export = BrandKitExport.new(kit, base_url: "")
    assert_equal BrandKitExport::FILES.keys + ["kit.json"], result.written
    assert_empty result.refused
    BrandKitExport::FILES.each_key do |name|
      assert_equal export.svg(name).b, @dir.join(name).binread, name
    end
    assert_equal({ "brand" => "studio", "icon" => nil, "navbar" => STUDIO_NAVBAR, "stacked" => STUDIO_STACKED, "motion" => nil, "saved_at" => nil,
                   "type_scale" => { "type_base" => 16, "type_dense_base" => 14, "type_display_weight" => 800, "type_text_weight" => 300 } },
                 JSON.parse(@dir.join("kit.json").read))
  end

  # Task brand-kit-applied-status: kit.json names the kit's version, so an app's live /brand/kit.json says which save
  # it serves (the brand-kit-rollout SOP reads it before `logos:applied`).
  test "the manifest carries the kit's saved_at in ISO 8601 UTC seconds" do
    kit = studio_kit
    kit.update!(saved_at: Time.utc(2026, 10, 27, 18, 4, 5, 123_456))
    BrandKitInstall.new(kit, dest: @dir).call
    assert_equal "2026-10-27T18:04:05Z", JSON.parse(@dir.join("kit.json").read)["saved_at"]
  end

  # Task logo-motion-presets: kit.json carries the kit's motion choice, and a kit read back from it carries it too.
  test "the manifest carries the motion choice, and kit_from_manifest round-trips and checks it" do
    kit = studio_kit
    kit.update!(motion_choice: { "preset" => "weight_flick", "logo" => "stacked" })
    BrandKitInstall.new(kit, dest: @dir).call
    json = @dir.join("kit.json").read
    assert_equal({ "preset" => "weight_flick", "logo" => "stacked" }, JSON.parse(json)["motion"])

    again = BrandKitInstall.kit_from_manifest(json, brand: "studio")
    assert_equal kit.motion_choice, again.motion_choice
    assert_equal BrandKitInstall.manifest_for(kit), BrandKitInstall.manifest_for(again)

    bad = JSON.parse(json).merge("motion" => { "preset" => "spin", "logo" => "stacked" }).to_json
    assert_match(/unknown motion preset/, assert_raises(ArgumentError) { BrandKitInstall.kit_from_manifest(bad, brand: "studio") }.message)
    none = JSON.parse(json).except("motion").to_json
    assert_nil BrandKitInstall.kit_from_manifest(none, brand: "studio").motion_choice, "a kit.json from before motion reads as no motion"
  end

  test "the saved choices reach the files: the navbar is the saved one, not the default" do
    kit = studio_kit
    BrandKitInstall.new(kit, dest: @dir).call
    refute_equal BrandKit.new(brand: "studio").variant(:navbar, tone: :light).svg.b, @dir.join("navbar-light.svg").binread,
                 "the saved navbar (first word 800, violet ending) differs from the brand default"
    assert_includes @dir.join("navbar-light.svg").read, "#8E82FE"
  end

  test "a second install rewrites nothing; a changed file is put back" do
    kit = studio_kit
    BrandKitInstall.new(kit, dest: @dir).call
    mtimes = @dir.children.to_h { |path| [path.basename.to_s, path.mtime] }

    again = BrandKitInstall.new(kit, dest: @dir).call
    assert_empty again.written
    assert_equal mtimes.keys.sort, again.unchanged.sort
    assert_equal mtimes, @dir.children.to_h { |path| [path.basename.to_s, path.mtime] }

    @dir.join("icon-light.svg").write("<svg>hand-edited</svg>")
    assert_equal ["icon-light.svg"], BrandKitInstall.new(kit, dest: @dir).call.written
    assert_equal BrandKitExport.new(kit, base_url: "").svg("icon-light.svg").b, @dir.join("icon-light.svg").binread
  end

  test "the rake task installs BRAND into DEST and refuses an unknown brand" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("logos:install")
    kit = studio_kit
    task = Rake::Task["logos:install"]
    out = with_env("BRAND" => "studio", "DEST" => @dir.to_s) { task.reenable; capture_io { task.invoke }.first }
    assert_match %r{wrote     #{Regexp.escape(@dir.join('navbar-dark.svg').to_s)}}, out
    assert_equal BrandKitExport.new(kit, base_url: "").svg("navbar-dark.svg").b, @dir.join("navbar-dark.svg").binread
    # Task brand-kit-carries-type-scale: it ends with the settings the app's initializer takes.
    assert_includes out, "type scale: set these in the app's config/initializers/studio.rb"
    assert_includes out, "  Studio.type_base = 16\n  Studio.type_dense_base = 14\n  Studio.type_display_weight = 800\n  Studio.type_text_weight = 300\n"

    out = with_env("BRAND" => "studio", "DEST" => @dir.to_s) { task.reenable; capture_io { task.invoke }.first }
    assert_no_match(/wrote/, out)
    assert_equal 10, out.scan("unchanged").size

    error = assert_raises(SystemExit) { with_env("BRAND" => "nope", "DEST" => @dir.to_s) { task.reenable; capture_io { task.invoke } } }
    refute error.success?
  end

  # Task brand-kit-applied-status: a rollout installs production's kit from its kit.json, so the desk's database
  # needs no copy of the row, and the app's kit.json names production's saved_at.
  test "FROM installs the kit a kit.json names, saved_at included, and refuses another brand or an undrawable choice" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("logos:install")
    task = Rake::Task["logos:install"]
    source = @dir.join("production-kit.json")
    source.write(JSON.generate("brand" => "studio", "icon" => nil, "navbar" => STUDIO_NAVBAR, "stacked" => STUDIO_STACKED,
                               "saved_at" => "2026-10-27T18:04:05Z"))
    dest = @dir.join("app")
    with_env("BRAND" => "studio", "DEST" => dest.to_s, "FROM" => source.to_s) { task.reenable; capture_io { task.invoke } }
    assert_equal "2026-10-27T18:04:05Z", JSON.parse(dest.join("kit.json").read)["saved_at"]
    assert_equal BrandKitExport.new(studio_kit, base_url: "").svg("navbar-light.svg").b, dest.join("navbar-light.svg").binread
    assert_equal 1, BrandKit.count, "nothing is written to this database"

    [JSON.generate("brand" => "turf"), JSON.generate("brand" => "studio", "navbar" => STUDIO_NAVBAR.merge("rule" => 99))].each do |bad|
      source.write(bad)
      error = assert_raises(SystemExit) { with_env("BRAND" => "studio", "DEST" => dest.to_s, "FROM" => source.to_s) { task.reenable; capture_io { task.invoke } } }
      refute error.success?
    end
  end

  # The committed public/brand/ files are the kit kit.json names, drawn by today's logo library: a change to the
  # library or the kit without a reinstall fails here. Fix: bin/rails logos:install BRAND=studio, with the kit saved.
  test "the hub's committed public/brand files match their manifest" do
    committed = BrandKitInstall.default_dest
    manifest = JSON.parse(committed.join("kit.json").read)
    kit = BrandKit.new(brand: manifest["brand"], icon_choice: manifest["icon"], navbar_choice: manifest["navbar"],
                       stacked_choice: manifest["stacked"])
    export = BrandKitExport.new(kit, base_url: "")
    BrandKitExport::FILES.each_key do |name|
      assert_equal export.svg(name).b, committed.join(name).binread,
                   "public/brand/#{name} is stale: run bin/rails logos:install BRAND=#{manifest['brand']}"
    end
  end

  private

  def with_env(vars)
    keys = vars.keys | %w[FROM]
    saved = keys.to_h { |key| [key, ENV[key]] }
    keys.each { |key| ENV[key] = vars[key] }
    yield
  ensure
    saved.each { |key, value| ENV[key] = value }
  end
end
