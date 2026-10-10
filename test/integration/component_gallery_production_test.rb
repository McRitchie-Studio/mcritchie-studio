# frozen_string_literal: true

require "test_helper"
require "json"
require "tmpdir"
require "rbconfig"
require "etc"

# [integration] The component gallery on the LIVE hub (task
# hub-shows-lookbook-gallery-live). The hub bundles lookbook after studio-engine
# and sets Studio.lookbook_in_production = true, so production draws Lookbook at
# /admin/style/components behind the engine's admin router constraint.
#
# Rails.env is fixed per process, so this boots the hub in production in a child
# process (test/support/component_gallery_probe.rb) against this test's own
# database, and reads back what it drew and what each persona got:
#
#   - with the flag on (the hub as configured): the gallery and its assets are
#     drawn; an admin gets 200; a visitor and a signed-in non-admin get 404 from
#     the gallery, its preview pages and its assets;
#   - the control, with the flag off: nothing is drawn, and the same admin who
#     got 200 a moment earlier gets 404 too, so the 404s above are the gate and
#     not a broken mount.
#
# One boot answers both, because the probe redraws the routes for the control.
class ComponentGalleryProductionTest < ActiveSupport::TestCase
  ROOT = Rails.root.to_s
  PROBE = File.join(ROOT, "test/support/component_gallery_probe.rb")

  # Paths every persona is asked about; the probe's PATHS keys.
  GALLERY_PATHS = %w[gallery inspect preview_frame assets_css assets_js].freeze
  PREVIEW_PATHS = %w[previews_index previews_badge].freeze
  ALL_PATHS = (GALLERY_PATHS + PREVIEW_PATHS).freeze

  # The probe boots once per run of this file; every test reads the same result.
  def self.result
    @result ||= boot_production_probe
  end

  # This test's database as a URL, so the production child reads the same rows
  # (a parallel worker's own database included). The probe rolls back what it
  # writes. The username is always spelled out: database.yml's production block
  # names its own (mcritchie_studio), which would win over a URL without one.
  def self.database_url
    c = ActiveRecord::Base.connection_db_config.configuration_hash
    user = c[:username].presence || Etc.getpwuid.name
    auth = c[:password].present? ? "#{user}:#{c[:password]}" : user
    "postgresql://#{auth}@#{c[:host].presence || 'localhost'}#{":#{c[:port]}" if c[:port]}/#{c[:database]}"
  end

  def self.boot_production_probe
    Dir.mktmpdir("hub-gallery-probe") do |dir|
      out = File.join(dir, "result.json")
      env = {
        "RAILS_ENV" => "production",
        "DATABASE_URL" => database_url,
        "PROBE_RESULT" => out,
        "SECRET_KEY_BASE" => "hub-component-gallery-probe-not-a-real-secret",
        # A production boot refuses to start without its R2 connection
        # (config/initializers/00_storage_backend.rb). Placeholders: nothing
        # here reads or writes object storage.
        "R2_ENDPOINT" => "https://probe.r2.cloudflarestorage.com",
        "R2_ACCESS_KEY_ID" => "probe", "R2_SECRET_ACCESS_KEY" => "probe",
        "R2_PUBLIC_URL" => "https://assets.probe.example",
        "RAILS_LOG_LEVEL" => "fatal"
      }
      output = IO.popen(env, [RbConfig.ruby, File.join(ROOT, "bin/rails"), "runner", PROBE],
                        chdir: ROOT, err: %i[child out], &:read)
      raise "the production probe failed (exit #{$?.exitstatus}):\n#{output}" unless $?.success? && File.exist?(out)

      JSON.parse(File.read(out))
    end
  end

  def result = self.class.result
  def on = result.fetch("on")
  def off = result.fetch("off")

  def status(pass, persona, path) = pass.fetch(persona).fetch(path).fetch("status")

  test "the probe booted the hub as production does, with the hub's own flag" do
    assert_equal "production", result["env"]
    assert result["eager_load"], "the probe did not eager load, so it is not a production boot"
    assert_equal true, result["flag"], "config/initializers/studio.rb does not set lookbook_in_production"
  end

  test "with the flag on, production draws the gallery and its assets behind the wall" do
    assert on["mounted"]
    refute_empty on["gallery_routes"], "the gallery is not drawn"
    refute_empty on["asset_routes"], "Lookbook's assets are not routed"
    assert_empty on["preview_routes"], "ViewComponent's preview pages are drawn in production"
    refute on["rack_static"], "a public Rack::Static serves /lookbook-assets"
  end

  test "with the flag on, an admin gets 200 from the gallery, a preview and the assets" do
    GALLERY_PATHS.each do |path|
      assert_equal 200, status(on, "admin", path), "admin got #{status(on, 'admin', path)} on #{path}"
    end
    assert on["admin_gallery_lists_badge"], "the gallery does not list the engine's badge preview"
    assert on["admin_frame_renders_badge"], "the badge preview frame does not render the component"
  end

  test "with the flag on, a visitor and a non-admin get 404 on every gallery, asset and preview path" do
    %w[visitor member].each do |persona|
      ALL_PATHS.each do |path|
        assert_equal 404, status(on, persona, path), "#{persona} got #{status(on, persona, path)} on #{path}"
        refute on.dig(persona, path, "names_lookbook"), "#{persona}'s 404 on #{path} names Lookbook"
      end
    end
  end

  test "an admin, too, gets 404 from ViewComponent's preview pages, which production does not draw" do
    PREVIEW_PATHS.each { |path| assert_equal 404, status(on, "admin", path), "admin got a preview page at #{path}" }
  end

  # The control: the same boot with the flag off draws nothing, and the admin
  # who got 200 above gets 404, so the 404s above are the gate.
  test "control: with the flag off, production draws nothing and the admin gets 404 too" do
    refute off["mounted"]
    assert_empty off["gallery_routes"], "the gallery is drawn without the flag"
    assert_empty off["asset_routes"], "Lookbook's assets are routed without the flag"
    assert_empty off["preview_routes"]
    %w[visitor member admin].each do |persona|
      ALL_PATHS.each do |path|
        assert_equal 404, status(off, persona, path), "#{persona} got #{status(off, persona, path)} on #{path} with the flag off"
      end
    end
  end
end
