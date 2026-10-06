# frozen_string_literal: true

require "test_helper"
require_relative "../../support/email_image_fakes"

# [unit] One round makes two candidates, each cropped, stored under the
# brief's path, and stamped with generator, version, prompt, billable units and
# cost (nil = unpriced). The adapter is a recorder; nothing is spent.
class EmailImages::GenerateTest < ActiveSupport::TestCase
  include EmailImageFakes

  setup do
    Artifact.where(kind: "email_header").delete_all
    EmailImageBrief.delete_all
    ImageGeneration::Registry.reload!
    @brief = turf_brief
  end

  teardown { ImageGeneration::Registry.reload! }

  test "a round files two email_header artifacts with their provenance" do
    with_fake_header_generator do |stored|
      artifacts = EmailImages::Generate.call(@brief)

      assert_equal 2, artifacts.size
      artifacts.each do |a|
        assert_equal "email_header", a.kind
        assert_equal @brief.slug, a.brief_slug
        assert_equal "openai_image_header", a.generator
        assert_equal "gpt-5-2025-08-07@v1", a.generator_version
        assert_equal "https://api.openai.com/v1/responses", a.generator_endpoint
        assert_equal EmailImages::Prompt.call(@brief), a.prompt
        assert_equal 6_100, a.billable_units
        assert_nil a.cost_usd, "no rate is declared for this row: unpriced, never zero"
        assert_equal "6,100 tokens", a.billing_summary
        assert_empty a.subjects, "a header has no people"
      end
      assert_equal ["email_images"], stored.map { |s| s[:prefix] }.uniq
      assert_equal ["turf-monster/drop_signup_confirmation/new_player"], stored.map { |s| s[:subject] }.uniq
      assert(artifacts.all? { |a| a.image_url.start_with?("#{EmailImageFakes::STORED_PREFIX}email_images/turf-monster/") })
    end
  end

  test "what is stored is the 1200x600 crop, not the vendor's image" do
    with_fake_header_generator do |stored|
      EmailImages::Generate.call(@brief, count: 1)

      bytes = Base64.decode64(stored.sole[:source].split(",", 2).last)
      image = MiniMagick::Image.read(bytes)
      assert_equal [1200, 600, "JPEG"], [image.width, image.height, image.type]
    end
  end

  test "the adapter is asked for the tool size with the kit's references inline" do
    with_fake_header_generator do
      EmailImages::Generate.call(@brief, count: 1)

      call = EmailImageFakes::Adapter.calls.sole
      assert_equal "1536x1024", call[:image_size]
      assert_equal 2, call[:reference_urls].size, "the gator and the style anchor"
      assert call[:reference_urls].first.start_with?("data:image/webp;base64,")
    end
  end

  test "the count never exceeds the per-round ceiling" do
    with_fake_header_generator do
      assert_equal 2, EmailImages::Generate.call(@brief, count: 9).size
    end
  end

  test "check! refuses with the variable named when the key is absent" do
    with_env("OPENAI_API_KEY", nil) do
      error = assert_raises(EmailImages::Generate::NoGenerator) { EmailImages::Generate.new(@brief).check! }
      assert_includes error.message, "OPENAI_API_KEY"
    end
  end

  test "check! refuses once the rounds are spent" do
    @brief.update_columns(rounds_used: 4)
    with_env("OPENAI_API_KEY", "sk-test") do
      assert_raises(EmailImages::Generate::RoundsExhausted) { EmailImages::Generate.new(@brief.reload).check! }
    end
  end

  test "a generator override that cannot make headers is refused" do
    @brief.update!(generator_key: "openai_gpt5_sheet")
    with_env("OPENAI_API_KEY", "sk-test") do
      error = assert_raises(EmailImages::Generate::NoGenerator) { EmailImages::Generate.new(@brief).check! }
      assert_includes error.message, "openai_gpt5_sheet"
    end
  end
end
