# frozen_string_literal: true

require "test_helper"
require Rails.root.join("lib/middleware/digested_asset_cache")

# [unit] DigestedAssetCache: a year of cache on a fingerprinted /assets/ file, and
# nothing changed on anything else (see lib/middleware/digested_asset_cache.rb).
class DigestedAssetCacheTest < ActiveSupport::TestCase
  WEEK = "public, max-age=604800"
  DIGEST = "a" * 64

  def call(path, status: 200, headers: { "cache-control" => WEEK })
    app = ->(_env) { [ status, headers.dup, [ "body" ] ] }
    DigestedAssetCache.new(app).call(Rack::MockRequest.env_for(path))
  end

  test "a digested asset gets a year, immutable" do
    %W[/assets/application-#{DIGEST}.css /assets/controllers/nav-#{DIGEST}.js /assets/application-#{DIGEST}.css.gz].each do |path|
      _status, headers, _body = call(path)
      assert_equal "public, max-age=31536000, immutable", headers["cache-control"], path
    end
  end

  test "an old-spelling header is replaced, never doubled" do
    _status, headers, _body = call("/assets/application-#{DIGEST}.css", headers: { "Cache-Control" => WEEK })
    assert_equal [ "cache-control" ], headers.keys.select { |name| name.casecmp?("cache-control") }
    assert_equal DigestedAssetCache::ONE_YEAR, headers["cache-control"]
  end

  test "an unfingerprinted file keeps the week" do
    [ "/denver-hero.avif", "/agents/carl.webp", "/brand/navbar-dark.svg", "/assets/application.css",
      "/assets/application-#{"a" * 8}.css", "/hero/denver-hero-#{DIGEST}.avif" ].each do |path|
      _status, headers, _body = call(path)
      assert_equal WEEK, headers["cache-control"], path
    end
  end

  test "a miss is never cached for a year" do
    _status, headers, _body = call("/assets/application-#{DIGEST}.css", status: 404, headers: {})
    assert_nil headers["cache-control"]
  end

  # [integration] Through the real stack: ActionDispatch::Static serves the file
  # from public/assets, and the header that reaches the client is the year.
  class ThroughStaticTest < ActionDispatch::IntegrationTest
    setup do
      @file = Rails.root.join("public/assets/digested-asset-cache-probe-#{SecureRandom.hex(32)}.txt")
      @made_dir = !@file.dirname.exist?
      FileUtils.mkdir_p(@file.dirname)
      File.write(@file, "probe")
    end

    # Leave public/ as it was: a stray public/assets breaks a release check.
    teardown do
      FileUtils.rm_f(@file)
      Dir.rmdir(@file.dirname) if @made_dir && Dir.empty?(@file.dirname)
    end

    test "a digested file served from public/assets carries a year" do
      get "/assets/#{@file.basename}"
      assert_response :success
      assert_equal "probe", response.body
      assert_equal DigestedAssetCache::ONE_YEAR, response.headers["cache-control"]
    end

    test "an unfingerprinted public file does not" do
      get "/robots.txt"
      assert_response :success
      refute_match(/max-age=31536000/, response.headers["cache-control"].to_s)
    end
  end
end
