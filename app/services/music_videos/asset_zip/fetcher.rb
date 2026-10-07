# frozen_string_literal: true

require "net/http"

module MusicVideos
  module AssetZip
    # The bytes of one manifest entry, yielded as they arrive and never held
    # whole: an R2 object through Studio::S3's client (the store this app's
    # STUDIO_S3_BACKEND selects, so production reads the production bucket),
    # or a sheet image over https.
    #
    # A sheet URL is fetched only when Appearances::FetchableUrl.https? passes
    # (https, a public host), and so is every redirect it answers with. The
    # check reads the URL's text, so its limits are FetchableUrl's (no DNS
    # pinning). Every failure is a FetchFailed with a short reason.
    class Fetcher
      OPEN_TIMEOUT = 5
      READ_TIMEOUT = 20
      MAX_REDIRECTS = 3
      # A character sheet is a few MB; a host streaming past this is refused.
      MAX_REMOTE_BYTES = 50 * 1024 * 1024

      def initialize(client: nil, bucket: nil)
        @client = client
        @bucket = bucket
      end

      def each_chunk(entry, &)
        case entry.kind
        when :object then object(entry.source, &)
        when :url then remote(entry.source, &)
        else raise ArgumentError, "no bytes to fetch for a #{entry.kind} entry"
        end
      end

      private

      # get_object with a block streams the body to it; an error status is
      # buffered by the SDK and raised, never yielded.
      #
      # An error raised by the block itself (the zip's sink: a client that
      # went away raises Puma::ConnectionError there) or the network failing
      # mid-body is not retried, since chunks already went out: the SDK
      # finishes the R2 socket and raises NonRetryableStreamingError around
      # it. The block's own error is handed back as itself, so the Writer can
      # tell a disconnect from a failed read.
      def object(key, &blk)
        require "aws-sdk-s3"
        client.get_object(bucket:, key: Studio::S3.full_key(key), &blk)
        nil
      rescue Aws::S3::Plugins::NonRetryableStreamingError => e
        original = e.original_error
        raise FetchFailed, "storage read failed (#{original.class.name.demodulize})" if original.is_a?(Seahorse::Client::NetworkingError)

        raise original
      rescue Studio::S3::NotConfigured
        raise FetchFailed, "object storage is not configured here"
      rescue Aws::S3::Errors::NoSuchKey, Aws::S3::Errors::NotFound
        raise FetchFailed, "not in storage"
      rescue Aws::Errors::ServiceError, Aws::Errors::MissingCredentialsError, Seahorse::Client::NetworkingError => e
        raise FetchFailed, "storage read failed (#{e.class.name.demodulize})"
      end

      def remote(url, hops = 0, &blk)
        raise FetchFailed, "not an https public host" unless Appearances::FetchableUrl.https?(url)

        uri = URI.parse(url)
        location = nil
        Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
          http.request(Net::HTTP::Get.new(uri)) do |response|
            case response
            when Net::HTTPSuccess then read_capped(response, &blk)
            when Net::HTTPRedirection then location = URI.join(url, response["location"].to_s).to_s
            else raise FetchFailed, "the host answered HTTP #{response.code}"
            end
          end
        end
        return unless location
        raise FetchFailed, "more than #{MAX_REDIRECTS} redirects" if hops >= MAX_REDIRECTS

        remote(location, hops + 1, &blk)
      rescue URI::InvalidURIError
        raise FetchFailed, "not a valid address"
      rescue SocketError, Timeout::Error, OpenSSL::SSL::SSLError, SystemCallError, IOError, Net::HTTPBadResponse,
             Net::ProtocolError => e
        raise FetchFailed, "the host could not be read (#{e.class.name.demodulize})"
      end

      def read_capped(response)
        bytes = 0
        response.read_body do |chunk|
          bytes += chunk.bytesize
          raise FetchFailed, "larger than #{MAX_REMOTE_BYTES / 1024 / 1024} MB" if bytes > MAX_REMOTE_BYTES

          yield chunk
        end
      end

      def client = @client ||= Studio::S3.client

      def bucket = @bucket ||= Studio::S3.bucket
    end
  end
end
