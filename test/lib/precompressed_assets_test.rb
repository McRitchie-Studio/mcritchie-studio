# frozen_string_literal: true

require "test_helper"

# [unit] PrecompressedAssets writes the .gz sidecars Sprockets used to, for the
# files the Propshaft manifest names, and only for the types FileHandler serves
# compressed (lib/precompressed_assets.rb).
class PrecompressedAssetsTest < ActiveSupport::TestCase
  setup do
    @dir = Pathname(Dir.mktmpdir("precompressed-assets"))
    @css = write("application-0f3c9a1e.css", "body { color: red; }\n" * 50)
    @js = write("controllers/nav-1a2b3c4d.js", "export default 1;\n" * 50)
    @svg = write("logo-icon-9e8d7c6b.svg", "<svg></svg>\n" * 50)
    @png = write("resend-favicon-5a5a5a5a.png", "\x89PNG".b * 50)
    @stale = write("old-00000000.css", "stale")
    manifest = { "application.css" => @css, "controllers/nav.js" => @js, "logo-icon.svg" => @svg,
                 "resend-favicon.png" => @png }.transform_values { |p| { "digested_path" => p.relative_path_from(@dir).to_s } }
    @dir.join(".manifest.json").write(JSON.dump(manifest))
  end

  teardown { FileUtils.rm_rf(@dir) }

  def write(name, body)
    path = @dir.join(name)
    FileUtils.mkdir_p(path.dirname)
    path.binwrite(body)
    path
  end

  test "writes a gzip sidecar that inflates to the file, for css, js and svg" do
    written = PrecompressedAssets.new(@dir).write!

    assert_equal [ @css, @js, @svg ].map { |p| "#{p}.gz" }.sort, written.map(&:to_s).sort
    [ @css, @js, @svg ].each do |source|
      gz = Pathname("#{source}.gz")
      assert_equal source.binread, Zlib.gunzip(gz.binread), "#{gz.basename} is not #{source.basename}"
      assert_operator gz.size, :<, source.size
    end
  end

  test "skips a type FileHandler never serves compressed, and a file the manifest does not name" do
    PrecompressedAssets.new(@dir).write!

    refute Pathname("#{@png}.gz").exist?, "a png sidecar is never read"
    refute Pathname("#{@stale}.gz").exist?, "a file outside the manifest was compressed"
  end

  test "a second run rewrites nothing that is current" do
    PrecompressedAssets.new(@dir).write!
    assert_empty PrecompressedAssets.new(@dir).write!
  end

  test "prunes a sidecar whose file is gone" do
    orphan = write("gone-11111111.css.gz", "x")
    PrecompressedAssets.new(@dir).write!
    refute orphan.exist?
    assert Pathname("#{@css}.gz").exist?
  end

  test "answers nothing without a manifest" do
    @dir.join(".manifest.json").delete
    assert_empty PrecompressedAssets.new(@dir).write!
  end

  test "assets:precompile runs the precompress step" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("assets:precompress")
    actions = Rake::Task["assets:precompile"].actions.map { |a| a.source_location&.first.to_s }
    assert actions.any? { |file| file.end_with?("lib/tasks/precompressed_assets.rake") },
           "assets:precompile no longer writes the gzip sidecars"
  end
end
