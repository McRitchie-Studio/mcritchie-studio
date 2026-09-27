require "test_helper"
require "rake"

# [unit] The gender helpers in lib/tasks/pokemon.rake (tasks/pokemon-mascot-gender):
# the nidoran family row fetch derives from its two species rows, the per-branch
# gender rules, and the ADDITIVE female-sprite upload that never overwrites a key.
# The rake file defines its helpers as private methods on the top-level object, so
# they are reached with `send` on a plain Object.
class PokemonRakeGenderTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("pokemon:fetch")
    @rake = Object.new
  end

  def row(dex, slug, base: slug, evolution: [], **extra)
    { "dex" => dex, "slug" => slug, "name" => slug.capitalize, "types" => ["poison"], "base" => base,
      "evolution" => evolution, "baby" => [], "avatar_url" => "https://s3/#{dex}-#{slug}-cropped.png" }.merge(extra)
  end

  def nidoran_rows
    [row(29, "nidoran-f", evolution: ["nidorina"]), row(30, "nidorina", base: "nidoran-f", evolution: ["nidoqueen"]),
     row(31, "nidoqueen", base: "nidoran-f"), row(32, "nidoran-m", evolution: ["nidorino"]),
     row(33, "nidorino", base: "nidoran-m", evolution: ["nidoking"]), row(34, "nidoking", base: "nidoran-m")]
  end

  test "stamp_gender_families adds one nidoran row and re-roots both lines on it" do
    rows = nidoran_rows
    @rake.send(:stamp_gender_families, rows)
    by = rows.index_by { |r| r["slug"] }

    family = by.fetch("nidoran")
    assert_equal 29, family["dex"], "the family wears Nidoran♀'s dex and art"
    assert_equal "https://s3/29-nidoran-f-cropped.png", family["avatar_url"]
    assert_equal "Nidoran", family["name"]
    assert_equal 4, family["gender_rate"]
    assert_equal %w[nidorina nidorino], family["evolution"]
    assert_equal({ "nidorina" => "female", "nidorino" => "male" }, family["evolution_genders"])
    assert_equal({ "female" => "nidoran-f", "male" => "nidoran-m" }, family["gender_forms"])

    %w[nidorina nidoqueen nidorino nidoking].each { |slug| assert_equal "nidoran", by[slug]["base"], slug }
    assert_equal "nidoran-f", by["nidoran-f"]["base"], "the legacy species rows keep their own line"
    assert_equal ["nidorino"], by["nidoran-m"]["evolution"]

    @rake.send(:stamp_gender_families, rows)
    assert_equal 1, rows.count { |r| r["slug"] == "nidoran" }, "a re-run replaces, never duplicates"
  end

  test "stamp_evolution_genders only stamps branches whose target is present" do
    rows = [row(280, "ralts", evolution: ["kirlia"]), row(281, "kirlia", evolution: %w[gardevoir gallade]),
            row(282, "gardevoir"), row(475, "gallade"), row(412, "burmy", evolution: ["mothim"]), row(414, "mothim")]
    @rake.send(:stamp_evolution_genders, rows)
    by = rows.index_by { |r| r["slug"] }

    assert_equal({ "gallade" => "male" }, by["kirlia"]["evolution_genders"])
    assert_equal({ "mothim" => "male" }, by["burmy"]["evolution_genders"], "no Wormadam row, no Wormadam rule")
    assert_nil by["ralts"]["evolution_genders"]
  end

  # A stand-in S3 client: head_object answers from a key set, put_object records.
  class FakeS3
    attr_reader :puts

    def initialize(existing)
      @existing = existing
      @puts = []
    end

    def head_object(bucket:, key:)
      raise Aws::S3::Errors::NotFound.new(nil, "Not Found") unless @existing.include?(key)

      { bucket: bucket, key: key }
    end

    def put_object(**args)
      @puts << args[:key]
    end
  end

  def png_response
    Net::HTTPOK.new("1.1", "200", "OK").tap do |ok|
      ok["content-type"] = "image/png"
      ok.instance_variable_set(:@read, true)
      ok.instance_variable_set(:@body, "PNG")
    end
  end

  test "put_image_if_absent never overwrites a key already in the bucket" do
    require "aws-sdk-s3"
    s3 = FakeS3.new(["pokemon/3-venusaur-female-sprite.png"])
    fetched = false
    Net::HTTP.stub(:get_response, lambda { |*|
      fetched = true
      png_response
    }) do
      refute @rake.send(:put_image_if_absent, s3, "bucket", "pokemon/3-venusaur-female-sprite.png", "https://cdn/3.png")
    end

    assert_empty s3.puts
    refute fetched, "an existing key is not even re-downloaded"
  end

  test "put_image_if_absent uploads an absent key from a verified image source" do
    require "aws-sdk-s3"
    s3 = FakeS3.new([])
    Net::HTTP.stub(:get_response, png_response) do
      assert @rake.send(:put_image_if_absent, s3, "bucket", "pokemon/3-venusaur-female-sprite.png", "https://cdn/3.png")
    end
    assert_equal ["pokemon/3-venusaur-female-sprite.png"], s3.puts

    missing = Net::HTTPNotFound.new("1.1", "404", "Not Found")
    Net::HTTP.stub(:get_response, missing) do
      assert_raises(RuntimeError) do
        @rake.send(:put_image_if_absent, s3, "bucket", "pokemon/4-x-female-sprite.png", "https://cdn/4.png")
      end
    end
    assert_equal 1, s3.puts.size, "a CDN 404 is never stored as a sprite"
  end
end
