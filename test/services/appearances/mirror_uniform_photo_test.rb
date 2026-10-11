require "test_helper"

# [unit] A CHOSEN UNIFORM PHOTO IS COPIED TO OUR STORAGE BEFORE ANY BUILD CAN SEND IT
# (Carl's block). The cache is a fake: nothing here fetches or uploads. Synthetic people.
class Appearances::MirrorUniformPhotoTest < ActiveSupport::TestCase
  class FakeCache
    Row = Struct.new(:url)
    attr_reader :fetched, :stored

    def initialize(body: "\x89PNG".b, type: "image/png", raises: nil)
      @body = body
      @type = type
      @raises = raises
      @fetched = []
      @stored = []
    end

    def fetch(url)
      @fetched << url
      raise @raises if @raises

      [@body, @type]
    end

    def cache!(owner:, key_prefix:, content_type:, **)
      @stored << [owner, key_prefix, content_type]
      { "original" => Row.new("https://assets.example.test/#{key_prefix}/original.png") }
    end
  end

  setup do
    Appearance.delete_all
    person = Person.create!(first_name: "Quill", last_name: "Mirrorfixture")
    @look = Appearance.create!(person_slug: person.slug, descriptor: "Comets home")
    @photo = @look.uniform_photos.create!(image_url: "https://img.example.test/u.jpg")
  end

  test "a copy is stored through the vetted cache and its address lands on the row" do
    cache = FakeCache.new

    url = Appearances::MirrorUniformPhoto.call(@photo, cache: cache)

    assert_equal ["https://img.example.test/u.jpg"], cache.fetched
    assert_equal "uniform-photos/#{@look.slug}/#{@photo.slug}", cache.stored.sole[1]
    assert_equal url, @photo.reload.hosted_url
    assert url.start_with?("https://assets.example.test/uniform-photos/")
  end

  test "a photo already copied is not fetched again" do
    @photo.update!(hosted_url: "https://assets.example.test/already.png")
    cache = FakeCache.new

    assert_equal "https://assets.example.test/already.png", Appearances::MirrorUniformPhoto.call(@photo, cache: cache)
    assert_empty cache.fetched
  end

  test "a refused address, a hotlink error, a non-image and an oversize body each refuse with a reason" do
    cases = {
      FakeCache.new(raises: Studio::ImageCache::InvalidSourceURL.new("resolves to a private address")) => /address was refused/,
      FakeCache.new(raises: StandardError.new("HTTP 403")) => /would not hand it over \(HTTP 403\)/,
      FakeCache.new(type: "text/html") => %r{served text/html, not an image},
      FakeCache.new(body: "x" * (ImageGeneration::OpenAI::MAX_REFERENCE_BYTES + 1)) => /too large to send/
    }
    cases.each do |cache, reason|
      error = assert_raises(Appearances::MirrorUniformPhoto::Refused) { Appearances::MirrorUniformPhoto.call(@photo, cache: cache) }
      assert_match reason, error.message
      assert_empty cache.stored
      assert_nil @photo.reload.hosted_url
    end
  end

  test "a generic served type is read from the extension" do
    cache = FakeCache.new(type: "application/octet-stream")
    Appearances::MirrorUniformPhoto.call(@photo, cache: cache)

    assert_equal "image/jpeg", cache.stored.sole[2]
  end

  test "with no cache injected under the suite's trap, nothing live is attempted" do
    assert_raises(Appearances::LiveCallTrap::LiveCallAttempted) { Appearances::MirrorUniformPhoto.call(@photo) }
  end
end
