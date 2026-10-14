# frozen_string_literal: true

require "test_helper"
require "rake"

# [unit] BrandKitInstall and `logos:install` (task studio-adopts-its-kit): a brand's saved kit written into an app's
# public/brand/, each file byte-equal to what /logos/:brand/kit/<file> serves, and a second install a no-op.
class BrandKitInstallTest < ActiveSupport::TestCase
  # The studio kit Alex saved on production, 2026-10-14 05:25Z: the hub's own branding is drawn from it.
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
    assert_equal({ "brand" => "studio", "icon" => nil, "navbar" => STUDIO_NAVBAR, "stacked" => STUDIO_STACKED },
                 JSON.parse(@dir.join("kit.json").read))
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

    out = with_env("BRAND" => "studio", "DEST" => @dir.to_s) { task.reenable; capture_io { task.invoke }.first }
    assert_no_match(/wrote/, out)
    assert_equal 10, out.scan("unchanged").size

    error = assert_raises(SystemExit) { with_env("BRAND" => "nope", "DEST" => @dir.to_s) { task.reenable; capture_io { task.invoke } } }
    refute error.success?
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
    saved = vars.keys.to_h { |key| [key, ENV[key]] }
    vars.each { |key, value| ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| ENV[key] = value }
  end
end
