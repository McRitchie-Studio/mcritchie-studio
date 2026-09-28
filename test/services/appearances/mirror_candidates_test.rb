require "test_helper"

# [unit] TAKING OUR OWN COPY OF A CANDIDATE — what gets mirrored, what it is called in
# the bucket, what we claim the bytes are, and what happens when any of it fails.
#
# ZERO NETWORK AND ZERO S3, BY CONSTRUCTION. The cache is injected (`cache:`) and
# Appearances::LiveCallTrap refuses the un-injected path outright — see
# live_call_trap_test.rb, which proves the refusal rather than assuming it. `FakeCache`
# below neither fetches nor uploads; it records what it was asked for.
class Appearances::MirrorCandidatesTest < ActiveSupport::TestCase
  Mirror = Appearances::MirrorCandidates

  # A CACHE THAT CACHES NOTHING. Mimics Studio::ImageCache.cache!'s signature and its
  # return shape — a Hash keyed by variant, whose values answer #url — and records
  # every call so the test can assert on the arguments rather than only on the answer.
  #
  # `served:` is what the source host answers our own fetch with: [body, Content-Type].
  class FakeCache
    Row = Struct.new(:url)
    JPEG = "\xFF\xD8\xFF\xE0fake-jpeg".b

    attr_reader :calls, :fetched

    def initialize(raises: nil, variants: ["original"], served: [JPEG, "image/jpeg"])
      @raises = raises
      @variants = variants
      @served = served
      @calls = []
      @fetched = []
    end

    def fetch(url)
      @fetched << url
      @served
    end

    def cache!(owner:, purpose:, key_prefix:, widths:, source_url:, source_path:, content_type:)
      @calls << { owner: owner, purpose: purpose, key_prefix: key_prefix, widths: widths,
                  source_url: source_url, content_type: content_type,
                  bytes: File.binread(source_path) }
      raise @raises if @raises

      @variants.index_with { |variant| Row.new("https://bucket.s3.test/#{key_prefix}/#{variant}.png") }
    end
  end

  setup do
    Appearance.delete_all
    AppearanceReferencePhoto.delete_all
    @person = people(:josh_allen)
    @look = Appearance.create!(person_slug: @person.slug, descriptor: "Bills home")
  end

  def photo(url: "https://upload.wikimedia.org/commons/f/f3/Player.png", **rest)
    AppearanceReferencePhoto.create!(
      appearance_slug: @look.slug, image_url: url,
      source: AppearanceReferencePhoto::SOURCE_SEARCH, **rest
    )
  end

  # ── THE ANSWER'S SHAPE ──────────────────────────────────────────────────────────

  # THE REMOTE URL IS THE KEY, and that is load-bearing rather than incidental:
  # everything in GatherReferencePhotos downstream of the mirror keys on the
  # provider's `image_url` — the rows, the merit memo, the rejection reasons — so a
  # map keyed the other way would leak a second identity for one photograph through
  # the whole object.
  test "it answers remote url => our url" do
    row = photo
    cache = FakeCache.new

    hosted = Mirror.call([row], cache: cache)

    assert_equal [row.image_url], hosted.keys
    assert_equal "https://bucket.s3.test/reference-photos/#{@look.slug}/#{row.slug}/original.png",
                 hosted[row.image_url]
    refute_equal row.image_url, hosted[row.image_url],
                 "the whole point is that what comes back is NOT the provider's URL"
  end

  # THE OWNER IS THE CANDIDATE ROW, NOT THE LOOK. ImageCache validates `variant`
  # unique per (owner, purpose), so a look-owned mirror would let the first candidate
  # claim the only "original" slot and every later one collide. Worse than colliding:
  # `cache!` is idempotent on that key and would RETURN THE FIRST CANDIDATE'S COPY for
  # the second candidate, so the classifier would silently score the wrong photograph.
  test "each candidate owns its own cache row, so no two can collide" do
    first = photo(url: "https://upload.wikimedia.org/a.png")
    second = photo(url: "https://upload.wikimedia.org/b.png")
    cache = FakeCache.new

    Mirror.call([first, second], cache: cache)

    assert_equal [first, second], cache.calls.map { |c| c[:owner] }
    assert_equal [Mirror::PURPOSE, Mirror::PURPOSE], cache.calls.map { |c| c[:purpose] }
    assert_equal 2, cache.calls.map { |c| c[:key_prefix] }.uniq.length,
                 "two candidates must never share an S3 key prefix"
  end

  test "the purpose is distinct from the headshot namespace it would otherwise collide with" do
    refute_equal Appearances::ReferenceImages::HEADSHOT_PURPOSE, Mirror::PURPOSE,
                 "athletes and candidate photographs must not share an ImageCache purpose, " \
                 "or nfl:rekey_headshots would sweep these copies too"
  end

  # ONE OBJECT PER CANDIDATE. A resized variant would buy a second S3 object and a
  # MiniMagick decode each, to serve a consumer that wants the full frame.
  test "only the original is asked for" do
    cache = FakeCache.new
    Mirror.call([photo], cache: cache)

    assert_equal [[]], cache.calls.map { |c| c[:widths] }
  end

  test "the key prefix names the look and the row, so an object in the bucket is traceable" do
    row = photo
    cache = FakeCache.new
    Mirror.call([row], cache: cache)

    assert_equal "#{Mirror::KEY_ROOT}/#{@look.slug}/#{row.slug}", cache.calls.first[:key_prefix]
  end

  # ── WHAT WE CLAIM THE BYTES ARE ─────────────────────────────────────────────────

  # THE ARCHIVE'S OWN CLAIM LEADS. `mime_type` is what the provider said the file is,
  # which outranks an extension parsed out of a URL.
  test "the provider's reported mime type is used when it is one we allow" do
    cache = FakeCache.new
    Mirror.call([photo(url: "https://x.test/no-extension", mime_type: "image/webp")], cache: cache)

    assert_equal "image/webp", cache.calls.first[:content_type]
  end

  test "a mime type outside the allowlist falls through to the extension" do
    cache = FakeCache.new
    Mirror.call([photo(url: "https://x.test/player.jpg", mime_type: "image/svg+xml")], cache: cache)

    assert_equal "image/jpeg", cache.calls.first[:content_type],
                 "an unsupported claim must not be passed through to raise inside cache!"
  end

  test "the extension answers when the provider volunteered nothing" do
    {
      "https://x.test/a.png" => "image/png",
      "https://x.test/a.jpg" => "image/jpeg",
      "https://x.test/a.JPEG" => "image/jpeg",
      "https://x.test/a.webp" => "image/webp",
      "https://x.test/a.gif" => "image/gif"
    }.each do |url, expected|
      cache = FakeCache.new
      Mirror.call([photo(url: url)], cache: cache)
      assert_equal expected, cache.calls.first[:content_type], url
    end
  end

  # READ OFF THE PATH, not the whole URL, so a query string cannot masquerade as the
  # file's type.
  test "a query string is not read as an extension" do
    cache = FakeCache.new
    Mirror.call([photo(url: "https://x.test/download?format=png")], cache: cache)

    assert_empty cache.calls, "an unknown type must not reach the cache at all"
  end

  # THE ONE ANSWER THAT IS NOT A GUESS. Guessing image/png over an unknown file would
  # put a wrong Content-Type on an object we serve; falling back to the remote URL
  # would reintroduce the entire bug.
  test "a type we cannot resolve is not mirrored and not smuggled through as a remote url" do
    row = photo(url: "https://x.test/mystery")
    cache = FakeCache.new

    hosted = Mirror.call([row], cache: cache)

    assert_empty hosted
    assert_empty cache.calls
    refute_includes hosted.values, row.image_url
  end

  # PINS THE TABLE AGAINST THE ENGINE'S ALLOWLIST. Our table is spelled out rather
  # than inverted from Studio::ImageCache::EXT_BY_TYPE (that Hash maps type->ext, has
  # no "jpeg" key, and elects the nonstandard "image/jpg" on `.invert`), so the day the
  # engine narrows its allowlist this is what notices.
  test "every content type we can produce is one the engine will accept" do
    unknown = Mirror::CONTENT_TYPE_BY_EXTENSION.values.uniq -
              Studio::ImageCache::ALLOWED_CONTENT_TYPES

    assert_empty unknown,
                 "#{Mirror}::CONTENT_TYPE_BY_EXTENSION would make cache! raise " \
                 "UnsupportedContentType on #{unknown.inspect}"
  end

  # ── WHAT THE HOST ACTUALLY SERVED ───────────────────────────────────────────────

  # Measured 2026-09-28: a Facebook crawler URL ending `.jpg` answered `text/html`. Both
  # claims said JPEG; the response's own Content-Type did not.
  test "[unit] an HTML response behind an image URL is refused" do
    row = photo(url: "https://lookaside.fbsbx.com/lookaside/crawler/media/x.jpg")
    cache = FakeCache.new(served: ["<html><body>login</body></html>", "text/html"])

    hosted = Mirror.call([row], target: @look, cache: cache)

    assert_empty hosted, "a page is not a photograph and must never reach the classifier"
    assert_empty cache.calls, "nothing is written to the bucket"
  end

  test "[unit] the refusal is filed against the look, naming the content type" do
    row = photo(url: "https://x.test/player.jpg")
    cache = FakeCache.new(served: ["<html>", "text/html"])

    assert_difference -> { ErrorLog.count }, 1 do
      Mirror.call([row], target: @look, cache: cache)
    end

    log = ErrorLog.order(:id).last
    assert_equal @look, log.target
    assert_includes log.message, "text/html"
    assert_includes log.message, row.image_url
  end

  test "[unit] a refused candidate does not cost the others" do
    good = photo(url: "https://x.test/good.jpg")
    bad = photo(url: "https://x.test/bad.jpg")
    cache = FakeCache.new
    cache.define_singleton_method(:fetch) do |url|
      url == bad.image_url ? ["<html>", "text/html"] : [FakeCache::JPEG, "image/jpeg"]
    end

    hosted = Mirror.call([good, bad], target: @look, cache: cache)

    assert_equal [good.image_url], hosted.keys
  end

  test "[unit] the bytes stored are the bytes whose content type was checked" do
    cache = FakeCache.new
    Mirror.call([photo], cache: cache)

    assert_equal FakeCache::JPEG, cache.calls.first[:bytes],
                 "a second fetch inside the cache could serve something the check never saw"
  end

  # A host that declares nothing specific is left to the claims below, as before.
  test "[unit] a generic binary content type is not refused" do
    cache = FakeCache.new(served: [FakeCache::JPEG, "application/octet-stream"])

    assert_equal 1, Mirror.call([photo], cache: cache).length
  end

  test "[unit] an image type we cannot store is refused" do
    cache = FakeCache.new(served: ["<svg/>", "image/svg+xml"])

    assert_empty Mirror.call([photo(url: "https://x.test/a.png")], cache: cache)
  end

  # ── THE DEGRADE ─────────────────────────────────────────────────────────────────

  # ONE DEAD CANDIDATE COSTS ONE PHOTOGRAPH. It must never cost the other eleven, and
  # it must never cost the page — every caller upstream is degrade-never-raise.
  test "a failure on one candidate leaves the others mirrored" do
    good = photo(url: "https://x.test/good.png")
    bad = photo(url: "https://x.test/bad.png")
    cache = FakeCache.new
    exploding = FakeCache.new(raises: Studio::ImageCache::SourceTooLarge.new("too big"))

    hosted = Mirror.call([good], cache: cache)
    assert_equal 1, hosted.length

    fell_over = Mirror.call([good, bad], cache: exploding)
    assert_empty fell_over, "a cache that always raises mirrors nothing, and raises nothing"
  end

  test "a raise inside the cache is swallowed rather than lost upward" do
    cache = FakeCache.new(raises: RuntimeError.new("S3 is having a minute"))

    assert_nothing_raised { Mirror.call([photo], cache: cache) }
  end

  # A CACHE THAT ANSWERS WITHOUT AN ORIGINAL is not an error but it is not a mirror
  # either, and reading it as one would hand the classifier a nil URL.
  test "a cache answer with no original variant mirrors nothing" do
    cache = FakeCache.new(variants: ["400"])

    assert_empty Mirror.call([photo], cache: cache)
  end

  test "a blank or nil candidate is skipped rather than raising" do
    cache = FakeCache.new

    assert_empty Mirror.call([nil], cache: cache)
    assert_empty cache.calls
  end

  # ── THE ROW READS ITS OWN COPY BACK ─────────────────────────────────────────────

  # WHY THIS MATTERS BEYOND TIDINESS: it is what makes a reject RE-JUDGEABLE. The
  # shortlist is mirrored, so every candidate a paid classifier actually judged has a
  # copy of its bytes that outlives the source host's mood.
  test "a mirrored row reads back its own hosted url, and an unmirrored one reads nil" do
    row = photo
    refute row.mirrored?
    assert_nil row.hosted_url

    ImageCache.create!(owner: row, purpose: Mirror::PURPOSE, variant: "original",
                       s3_key: "reference-photos/#{@look.slug}/#{row.slug}/original.png",
                       source_url: row.image_url, bytes: 222_045, content_type: "image/png")

    row.reload
    assert row.mirrored?
    assert_includes row.hosted_url, "reference-photos/#{@look.slug}/#{row.slug}/original.png"
    refute_equal row.image_url, row.hosted_url
  end

  # A HEADSHOT ROW'S CACHE MUST NOT BE MISTAKEN FOR A MIRROR. The reader filters on
  # purpose, so an unrelated cached image on the same owner cannot answer for one.
  test "a cache row under another purpose is not read as a mirror" do
    row = photo
    ImageCache.create!(owner: row, purpose: "headshot", variant: "original",
                       s3_key: "headshots/nfl/x/y/original.png", content_type: "image/png")

    assert_nil row.reload.hosted_url
  end
end
