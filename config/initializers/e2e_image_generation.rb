# frozen_string_literal: true

# THE E2E LANE'S STAND-IN SHEET GENERATOR. Only in the test env, and only when
# the Playwright server sets E2E_FAKE_IMAGE_GENERATION=1: every image adapter
# becomes a fake that returns a grey placeholder, and the upload keeps it as a
# data URI. No vendor or bucket is reached.
if Rails.env.test? && ENV["E2E_FAKE_IMAGE_GENERATION"] == "1"
  Rails.application.config.to_prepare do
    ENV["OPENAI_API_KEY"] ||= "e2e-fake"
    svg = '<svg xmlns="http://www.w3.org/2000/svg" width="500" height="200"><rect width="500" height="200" fill="#ccc"/></svg>'
    placeholder = "data:image/svg+xml;base64,#{Base64.strict_encode64(svg)}"

    fake = Class.new do
      define_method(:initialize) { |row| @row = row }
      define_method(:generate_and_wait) do |reference_urls:, **|
        raise ImageGeneration::GenerationFailed, "no references" if Array(reference_urls).empty?

        ImageGeneration::Result.new(image_urls: [placeholder], seed: nil, request_id: "e2e-fake",
                                    generator_key: @row.key, version: @row.provenance_version, billable_units: 7_000)
      end
    end

    ImageGeneration::Adapter.define_singleton_method(:for) { |_row| fake }
    Appearances::StoreGeneratedImage.define_singleton_method(:call) { |source, **| source.to_s }
  end
end
