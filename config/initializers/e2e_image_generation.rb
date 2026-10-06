# frozen_string_literal: true

# THE E2E LANE'S STAND-IN IMAGE GENERATOR (sheets and email headers). Only in the test env, and only when
# the Playwright server sets E2E_FAKE_IMAGE_GENERATION=1: every image adapter
# becomes a fake that returns a placeholder PNG, and the upload keeps it as a
# data URI. No vendor or bucket is reached. SheetBuildJob and EmailImageBuildJob run async.
if Rails.env.test? && ENV["E2E_FAKE_IMAGE_GENERATION"] == "1"
  Rails.application.config.to_prepare do
    ENV["OPENAI_API_KEY"] ||= "e2e-fake"
    # A PNG, not an SVG: email headers are cropped with MiniMagick
    # (EmailImages::Crop), which needs a raster. A 48x32 green block with a
    # lighter panel, so a cropped placeholder is visibly a placeholder.
    placeholder = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAADAAAAAgAgMAAAApuhOPAAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6mAAADqYAAAXcJy6UTwAAAAJUExURS59MoHHhP///y2ldAMAAAABYktHRAJmC3xkAAAAB3RJTUUH6goGFRUK2V27qAAAACV0RVh0ZGF0ZTpjcmVhdGUAMjAyNi0xMC0wNlQyMToyMToxMCswMDowMA9noZkAAAAldEVYdGRhdGU6bW9kaWZ5ADIwMjYtMTAtMDZUMjE6MjE6MTArMDA6MDB+OhklAAAAKHRFWHRkYXRlOnRpbWVzdGFtcAAyMDI2LTEwLTA2VDIxOjIxOjEwKzAwOjAwKS84+gAAABRJREFUGNNjYKAvCA0NdRi2HBoAAHGZFTDiMZwyAAAAAElFTkSuQmCC"

    fake = Class.new do
      define_method(:initialize) { |row| @row = row }
      define_method(:generate_and_wait) do |reference_urls:, **|
        raise ImageGeneration::GenerationFailed, "no references" if Array(reference_urls).empty?

        ImageGeneration::Result.new(image_urls: [placeholder], seed: nil, request_id: "e2e-fake",
                                    generator_key: @row.key, version: @row.provenance_version, billable_units: 7_629)
      end
    end

    ImageGeneration::Adapter.define_singleton_method(:for) { |_row| fake }
    Appearances::StoreGeneratedImage.define_singleton_method(:call) { |source, **| source.to_s }
    # The test adapter only records jobs; run the sheet build in-process so the
    # page can reach done. Scoped to this one job.
    SheetBuildJob.queue_adapter = :async
    EmailImageBuildJob.queue_adapter = :async
  end
end
