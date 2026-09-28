require "test_helper"

# [integration] The real Appearances::MirrorCandidates between a search and the classifier,
# with only the network and S3 faked. Replays 2026-09-27: a `.jpg` URL that served HTML.
class PoisonedCandidateTest < ActiveSupport::TestCase
  JPEG = "\xFF\xD8\xFF\xE0fake-jpeg".b

  # Serves HTML for the poisoned URL and a JPEG for every other; stores nothing.
  class HostAndBucket
    Row = Struct.new(:url)

    def initialize(poison) = @poison = poison

    def fetch(url) = url == @poison ? ["<html><body>log in</body></html>", "text/html"] : [JPEG, "image/jpeg"]

    def cache!(key_prefix:, **) = { "original" => Row.new("https://bucket.s3.test/#{key_prefix}/original.jpg") }
  end

  class RecordingFaces
    attr_reader :asked

    def initialize = @asked = []
    def available? = true

    def call(urls, target: nil)
      @asked.concat(urls)
      urls.to_h { |u| [u, Appearances::FaceVisibility::Judgement.new(visibility: 0.9, fill: 0.9)] }
    end
  end

  class OneAnswer
    def initialize(results) = @results = results
    def available? = true
    def provider_name = "fake"

    def search(query:, limit:, target: nil)
      Appearances::ImageSearch::Answer.new(results: @results, unparsed_count: 0, provider_name: "fake")
    end
  end

  setup do
    Appearance.delete_all
    AppearanceReferencePhoto.delete_all
    @look = Appearance.create!(person_slug: people(:josh_allen).slug, descriptor: "Bills home")
  end

  test "[integration] a poisoned candidate never reaches the classifier, and its neighbours do" do
    poison = "https://lookaside.fbsbx.com/lookaside/crawler/media/1.jpg"
    urls = [poison] + (2..5).map { |i| "https://cdn.example.com/#{i}.jpg" }
    results = urls.each_with_index.map do |url, i|
      Appearances::ImageSearch::Result.new(image_url: url, position: i + 1, title: "Josh Allen")
    end
    bucket = HostAndBucket.new(poison)
    mirror = ->(photos, target: nil) { Appearances::MirrorCandidates.call(photos, target: target, cache: bucket) }
    faces = RecordingFaces.new

    assert_difference -> { ErrorLog.where("message LIKE ?", "%text/html%").count }, 1 do
      Appearances::GatherReferencePhotos.call(@look, search: OneAnswer.new(results), faces: faces, mirror: mirror)
    end

    assert_equal 4, faces.asked.length, "the four real images are judged"
    refute(faces.asked.any? { |u| u.include?("lookaside") || u == poison })
  end
end
