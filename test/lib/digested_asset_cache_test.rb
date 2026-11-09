# frozen_string_literal: true

require "test_helper"
require Rails.root.join("lib/middleware/digested_asset_cache")

# [unit] DigestedAssetCache: a year of cache on a fingerprinted /assets/ file, and
# nothing changed on anything else (see lib/middleware/digested_asset_cache.rb).
class DigestedAssetCacheTest < ActiveSupport::TestCase
  WEEK = "public, max-age=604800"
  DIGEST = "a" * 64 # Sprockets 4, still on a slug precompiled before the move
  PROPSHAFT = "0f3c9a1e" # Propshaft: the first 8 hex of a SHA1

  def call(path, status: 200, headers: { "cache-control" => WEEK })
    app = ->(_env) { [ status, headers.dup, [ "body" ] ] }
    DigestedAssetCache.new(app).call(Rack::MockRequest.env_for(path))
  end

  test "a digested asset gets a year, immutable" do
    %W[/assets/application-#{PROPSHAFT}.css /assets/controllers/nav-#{PROPSHAFT}.js
       /assets/tailwind-#{PROPSHAFT}.css.gz /assets/hero/denver-hero-1280-#{PROPSHAFT}.avif
       /assets/application-#{DIGEST}.css /assets/controllers/nav-#{DIGEST}.js /assets/application-#{DIGEST}.css.gz].each do |path|
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
      "/assets/hero/denver-hero-1280.avif", "/assets/application-#{"a" * 7}.css",
      "/assets/application-#{"g" * 8}.css", "/hero/denver-hero-#{PROPSHAFT}.avif" ].each do |path|
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
    # Parallel workers share public/assets: one worker's teardown could remove
    # the folder between another's mkdir and write (ENOENT, engine consumer CI
    # run 42706278471). One lock holds each create-and-write and each
    # delete-and-remove whole.
    LOCK = Rails.root.join("tmp/digested-asset-cache-probe.lock")

    def self.locked
      FileUtils.mkdir_p(LOCK.dirname)
      File.open(LOCK, File::RDWR | File::CREAT) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    setup do
      @file = Rails.root.join("public/assets/digested-asset-cache-probe-#{SecureRandom.hex(4)}.txt")
      self.class.locked do
        FileUtils.mkdir_p(@file.dirname)
        File.write(@file, "probe")
      end
    end

    # Leave public/ as it was: a stray public/assets breaks a release check.
    # The folder goes only when the last probe leaves it empty.
    teardown do
      self.class.locked do
        FileUtils.rm_f(@file)
        Dir.rmdir(@file.dirname) if @file.dirname.exist? && Dir.empty?(@file.dirname)
      end
    end

    test "a digested file served from public/assets carries a year" do
      get "/assets/#{@file.basename}"
      assert_response :success
      assert_equal "probe", response.body
      assert_equal DigestedAssetCache::ONE_YEAR, response.headers["cache-control"]
    end

    test "an unfingerprinted public file does not" do
      %w[/agents/avi.webp /robots.txt].each do |path|
        get path
        assert_response :success
        refute_match(/max-age=31536000/, response.headers["cache-control"].to_s, path)
      end
    end
  end
end

# [unit] The probe lock is exclusive: while one probe is between its mkdir and
# its write, no other worker can take the lock, so no teardown can remove the
# folder under it.
class DigestedAssetCacheProbeLockTest < ActiveSupport::TestCase
  test "no other worker can take the probe lock inside a probe's setup" do
    inside = Queue.new
    go = Queue.new
    holder = Thread.new do
      DigestedAssetCacheTest::ThroughStaticTest.locked do
        inside << true
        go.pop
      end
    end
    inside.pop
    File.open(DigestedAssetCacheTest::ThroughStaticTest::LOCK, File::RDWR | File::CREAT) do |other|
      refute other.flock(File::LOCK_EX | File::LOCK_NB), "a second worker took the lock while a probe held it"
    end
  ensure
    go&.push(true)
    holder&.join
  end
end
