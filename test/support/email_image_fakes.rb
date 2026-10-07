# frozen_string_literal: true

# Shared stand-ins for the email header tests. Nothing here reaches a vendor
# or a bucket: the adapter is a recorder and the suite-wide
# OPENAI_NO_LIVE_CALLS trap is the backstop.
module EmailImageFakes
  # A real 1536x1024 PNG, built once, so EmailImages::Crop runs on the size
  # the image tool returns.
  def self.vendor_png
    @vendor_png ||= begin
      image = MiniMagick::Image.open(Rails.root.join("public/email_brand/turf-monster-style-anchor.jpg"))
      image.resize("1536x1024!")
      image.format("png")
      image.to_blob
    end
  end

  def self.vendor_data_uri = "data:image/png;base64,#{Base64.strict_encode64(vendor_png)}"

  # Records every call and answers a measured-shaped Result.
  class Adapter
    class << self
      attr_accessor :calls, :billable_units

      def reset!
        self.calls = []
        self.billable_units = 6_100
      end

      def new(row) = allocate.tap { |a| a.instance_variable_set(:@row, row) }
    end

    def generate_and_wait(**kwargs)
      self.class.calls << kwargs
      ImageGeneration::Result.new(image_urls: [EmailImageFakes.vendor_data_uri], seed: nil, request_id: "resp_fake",
                                  generator_key: @row.key, version: @row.provenance_version,
                                  billable_units: self.class.billable_units, cost_usd: @row.price_for(self.class.billable_units))
    end
  end

  STORED_PREFIX = "https://assets.example.test/".freeze

  # Runs the block with the fake adapter, a credential, and a store that
  # records the key it was asked for instead of uploading.
  def with_fake_header_generator
    EmailImageFakes::Adapter.reset!
    stored = []
    store = lambda do |source, prefix:, subject:, **|
      stored << { source: source, prefix: prefix, subject: subject }
      "#{STORED_PREFIX}#{prefix}/#{subject}/#{stored.size}.jpg"
    end
    ImageGeneration::Adapter.stub(:for, EmailImageFakes::Adapter) do
      Appearances::StoreGeneratedImage.stub(:call, store) do
        with_env("OPENAI_API_KEY", "sk-test") { yield stored }
      end
    end
  end

  # A tiny real PNG (the E2E placeholder's shape), for upload tests.
  def self.small_png
    @small_png ||= begin
      image = MiniMagick::Image.open(Rails.root.join("public/email_brand/turf-monster-style-anchor.jpg"))
      image.resize("48x32!")
      image.format("png")
      image.to_blob
    end
  end

  # An uploaded reference row, without the upload: the kit-merge and
  # selection tests only need the row.
  def brand_reference(**attrs)
    EmailBrandReference.create!({ brand_kit: "turf-monster", role: "mascot", label: "Gator, arms raised",
                                  image_url: "https://assets.example.test/email_brand/turf-monster/refs/a.png",
                                  content_type: "image/png", byte_size: 1_000 }.merge(attrs))
  end

  # An uploaded file the way a multipart request hands it to the controller.
  def uploaded(bytes, name:, type: "image/png")
    file = Tempfile.new(["upload", File.extname(name)])
    file.binmode
    file.write(bytes)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, type, true, original_filename: name)
  end

  def turf_brief(**attrs)
    EmailImageBrief.create!({ app: "turf-monster", email_key: "drop_signup_confirmation", variant: "new_player",
                              brand_kit: "turf-monster", headline: "You're In!" }.merge(attrs))
  end
end
