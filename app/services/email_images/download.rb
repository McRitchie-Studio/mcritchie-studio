# frozen_string_literal: true

require "base64"
require "net/http"

module EmailImages
  # THE BYTES BEHIND AN IMAGE URL this pipeline wrote: our bucket's https URL,
  # or the data URI the E2E fake stores in its place. Used by the export and by
  # bin/email-image to put candidates and brand assets on local disk, where an
  # agent can open them and show them to Alex.
  #
  # Reads only. A failure raises Failed with the URL and the HTTP status; it
  # never retries and never follows a redirect to somewhere else.
  module Download
    class Failed < StandardError; end

    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 60

    module_function

    def bytes(url)
      text = url.to_s
      return data_uri_bytes(text) if text.start_with?("data:")

      uri = URI.parse(text)
      raise Failed, "#{text.truncate(80).inspect} is not an http(s) URL" unless uri.is_a?(URI::HTTP)

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                     open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
        http.get(uri.request_uri)
      end
      raise Failed, "#{text} answered HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      response.body.to_s.b
    rescue URI::InvalidURIError => e
      raise Failed, "#{text.truncate(80).inspect} is not a URL: #{e.message}"
    end

    def data_uri_bytes(text)
      decoded = Base64.decode64(text.split(",", 2).last.to_s)
      raise Failed, "the stored data URI decoded to nothing" if decoded.empty?

      decoded
    end

    # The file extension the bytes actually are (JPG, PNG, WebP), whatever the
    # URL says. Falls back to the given default.
    def extension_for(bytes, default: "jpg")
      head = bytes.byteslice(0, 12).to_s.b
      return "png" if head.start_with?("\x89PNG".b)
      return "jpg" if head.start_with?("\xFF\xD8".b)
      return "webp" if head.start_with?("RIFF".b) && head.byteslice(8, 4) == "WEBP".b

      default
    end
  end
end
