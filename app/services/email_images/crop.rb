# frozen_string_literal: true

require "base64"

module EmailImages
  # GENERATED ART IN, AN EMAIL-READY HEADER OUT: exactly the preset's width and
  # height, JPG or PNG, under the email byte budget.
  #
  # DETERMINISTIC. The model is asked for 1536x1024 (the image tool's only
  # landscape size); this scales the picture to cover the preset and trims the
  # overflow equally from both sides (centre gravity), so the same input always
  # yields the same pixels. MiniMagick, the decoder the engine's ImageCache
  # already runs on every dyno.
  #
  # JPG steps its quality down from 85 until it fits the budget; a PNG that will
  # not fit is quantized to 256 colours. Either way the answer reports its own
  # byte size, and `over_budget?` says so rather than pretending.
  class Crop
    Output = Struct.new(:bytes, :content_type, :width, :height, :quality, keyword_init: true) do
      def bytesize = bytes.bytesize
      def over_budget?(max = EmailImages::BrandKit.max_bytes) = bytesize > max
      def data_uri = "data:#{content_type};base64,#{Base64.strict_encode64(bytes)}"
      def extension = content_type == "image/png" ? "png" : "jpg"
    end

    DATA_URI = %r{\Adata:[\w/\-.+]+;base64,(?<data>.+)\z}m
    JPG_QUALITIES = [85, 80, 75, 70, 65, 60].freeze

    class CropFailed < StandardError; end

    def self.call(source, **kwargs) = new(source, **kwargs).call

    def initialize(source, width:, height:, format: "jpg", max_bytes: EmailImages::BrandKit.max_bytes)
      @source = source
      @width = Integer(width)
      @height = Integer(height)
      @format = format.to_s == "png" ? "png" : "jpg"
      @max_bytes = max_bytes
    end

    def call
      input = decode(@source)
      @format == "png" ? png(input) : jpg(input)
    rescue CropFailed
      raise
    rescue StandardError => e
      raise CropFailed, "could not crop the generated image: #{e.class}: #{e.message}"
    end

    private

    def jpg(input)
      output = nil
      JPG_QUALITIES.each do |quality|
        output = render(input, quality: quality)
        break unless output.over_budget?(@max_bytes)
      end
      output
    end

    def png(input)
      output = render(input)
      output.over_budget?(@max_bytes) ? render(input, colors: 256) : output
    end

    def render(input, quality: nil, colors: nil)
      image = MiniMagick::Image.read(input)
      # FORMAT FIRST: mogrify writes back in the file's own format, so options
      # applied to the vendor's PNG and then converted would be lost (a 256-colour
      # palette re-expanded, a JPG quality applied to a PNG).
      image.format(@format == "png" ? "png" : "jpg")
      geometry = "#{@width}x#{@height}"
      image.combine_options do |c|
        c.limit "memory", "256MB"
        c.limit "map", "512MB"
        c.limit "width", "16KP"
        c.limit "height", "16KP"
        c.auto_orient
        c.colorspace "sRGB"
        c.resize "#{geometry}^"
        c.gravity "center"
        c.extent geometry
        c.strip
        c.colors colors.to_s if colors
        c.quality quality.to_s if quality
        c.background "white" if @format == "jpg"
        c.flatten if @format == "jpg"
      end
      bytes = image.to_blob
      Output.new(bytes: bytes, content_type: @format == "png" ? "image/png" : "image/jpeg",
                 width: image.width, height: image.height, quality: quality)
    end

    def decode(source)
      text = source.to_s
      if (match = DATA_URI.match(text))
        Base64.decode64(match[:data])
      elsif text.bytesize.positive? && !text.start_with?("http")
        text.b
      else
        raise CropFailed, "expected image bytes or a data URI, got #{text.truncate(40).inspect}"
      end
    end
  end
end
