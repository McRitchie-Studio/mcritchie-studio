module Broadcasts
  # Standard publish/save/delete for broadcast email images, layered on the
  # shared Studio::S3 module (studio-engine). Email clients can't load localhost
  # or expiring URLs, so images live in S3 under the "email/" prefix and are
  # referenced by their stable PUBLIC bucket URL.
  #
  #   Broadcasts::Assets.publish_all!   # push public/email/* to S3
  #   Broadcasts::Assets.base_url       # "https://<bucket>.s3.<region>.amazonaws.com"
  #   Broadcasts::Assets.delete("world_cup_header.png")
  module Assets
    PREFIX = "email".freeze
    SOURCE_DIR = Rails.root.join("public", PREFIX).freeze
    CONTENT_TYPES = { ".png" => "image/png", ".jpg" => "image/jpeg", ".jpeg" => "image/jpeg" }.freeze
    CACHE_CONTROL = "public, max-age=31536000, immutable".freeze

    class << self
      # Public base URL for the bucket (no trailing slash). The email shell
      # builds "#{base_url}/email/<file>", matching the keys we upload. Reuses the
      # engine's URL format (Studio::S3.url) so the scheme never drifts.
      def base_url
        Studio::S3.url(key: "").chomp("/")
      end

      # Upload every image in public/email/ to S3 under "email/<file>".
      # Returns { filename => public_url }.
      def publish_all!
        Dir.glob(SOURCE_DIR.join("*")).each_with_object({}) do |path, out|
          next unless File.file?(path)

          ext = File.extname(path).downcase
          next unless CONTENT_TYPES.key?(ext)

          out[File.basename(path)] = publish(path)
        end
      end

      # Upload a single local file; returns its public URL.
      def publish(path)
        filename = File.basename(path)
        Studio::S3.upload(
          key: key_for(filename),
          body: File.binread(path),
          content_type: CONTENT_TYPES[File.extname(path).downcase],
          cache_control: CACHE_CONTROL
        )
      end

      def delete(filename)
        Studio::S3.delete(key: key_for(filename))
      end

      def published?(filename)
        Studio::S3.exists?(key: key_for(filename))
      end

      def key_for(filename)
        "#{PREFIX}/#{filename}"
      end
    end
  end
end
