# frozen_string_literal: true

require "net/http"
require "timeout"

module MusicVideos
  module AssetZip
    # The bytes of one manifest entry, yielded as they arrive and never held
    # whole: an R2 object through Studio::S3's client (the store this app's
    # STUDIO_S3_BACKEND selects, so production reads the production bucket),
    # or a sheet image over https.
    #
    # A sheet URL is fetched only when it is https and the engine's URL guard
    # (`Studio::ImageCache.vet_source_url!`) passes it: a public host, however
    # it is written and wherever its name resolves. The connection is then made
    # to the ADDRESS THAT WAS VETTED (`Studio::ImageCache.pinned_http`), so a
    # name that answers differently a moment later is not followed. Every
    # redirect is a new URL and gets the same check and its own pinned
    # connection. Every failure is a FetchFailed with a short reason, which the
    # Writer lists in the README; it never ends the zip.
    #
    # The guard is asked directly, not through Appearances::FetchableUrl: that
    # module remembers a verdict, and this needs the addresses. So each fetched
    # sheet is one lookup (the engine allows it six seconds), made while the
    # body streams, where no request budget applies. Under a Rails test
    # environment the engine resolves nothing unless a test sets a resolver.
    #
    # ONE CONNECT DEADLINE PER ENTRY. While a connection opens, no byte goes
    # out on the download, and Heroku cuts a response that is silent for 55
    # seconds. A timeout per address would let a host with four dead addresses
    # hold the stream four times as long, so OPEN_TIMEOUT is spent once for the
    # whole entry: across every vetted address and every redirect hop, TCP and
    # TLS together. An address is given only what is left of it; when it is
    # spent, no further address is tried and the entry is a README line.
    class Fetcher
      # Seconds one entry may spend opening connections, in all.
      OPEN_TIMEOUT = 5
      READ_TIMEOUT = 20
      MAX_REDIRECTS = 3
      # A character sheet is a few MB; a host streaming past this is refused.
      MAX_REMOTE_BYTES = 50 * 1024 * 1024
      # A connection that never opened: the next vetted address is tried.
      UNREACHABLE = [Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::EADDRNOTAVAIL,
                     Net::OpenTimeout, SocketError].freeze

      def initialize(client: nil, bucket: nil, open_timeout: OPEN_TIMEOUT)
        @client = client
        @bucket = bucket
        @open_timeout = open_timeout
      end

      def each_chunk(entry, &)
        case entry.kind
        when :object then object(entry.source, &)
        when :url then remote(entry.source, 0, ConnectBudget.new(@open_timeout, -> { clock }), &)
        else raise ArgumentError, "no bytes to fetch for a #{entry.kind} entry"
        end
      end

      # What is left of one entry's connect deadline. Only time spent opening a
      # connection is charged to it (`spend`), never the lookup or the read.
      class ConnectBudget
        def initialize(seconds, clock)
          @left = seconds.to_f
          @clock = clock
        end

        attr_reader :left

        def spent? = @left <= 0

        def spend
          started = @clock.call
          yield
        ensure
          @left -= @clock.call - started
        end
      end

      private

      # A monotonic clock, as a method so a test can move it.
      def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

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

      def remote(url, hops, budget, &blk)
        vetted = vet(url)
        location = nil
        connected(vetted, budget) do |http|
          http.request(Net::HTTP::Get.new(vetted.uri)) do |response|
            case response
            when Net::HTTPSuccess then read_capped(response, &blk)
            when Net::HTTPRedirection then location = URI.join(url, response["location"].to_s).to_s
            else raise FetchFailed, "the host answered HTTP #{response.code}"
            end
          end
        end
        return unless location
        raise FetchFailed, "more than #{MAX_REDIRECTS} redirects" if hops >= MAX_REDIRECTS

        remote(location, hops + 1, budget, &blk)
      rescue URI::InvalidURIError
        raise FetchFailed, "not a valid address"
      rescue SocketError, Timeout::Error, OpenSSL::SSL::SSLError, SystemCallError, IOError, Net::HTTPBadResponse,
             Net::ProtocolError => e
        raise FetchFailed, "the host could not be read (#{e.class.name.demodulize})"
      end

      # The URL, vetted: https only, and the addresses its host was vetted
      # against. A name that could not be looked up is not a bad address, and
      # says so.
      def vet(url)
        raise FetchFailed, "not an https public host" unless URI.parse(url.to_s).scheme.to_s.casecmp?("https")

        Studio::ImageCache.vet_source_url!(url.to_s)
      rescue Studio::ImageCache::UnresolvedSourceHost
        raise FetchFailed, "the host could not be looked up just now"
      rescue Studio::ImageCache::InvalidSourceURL, URI::InvalidURIError
        raise FetchFailed, "not an https public host"
      end

      # An open connection to the first vetted address that accepts one, closed
      # when the block ends. An address that cannot be reached (an AAAA record
      # where there is no IPv6 route) falls through to the next, in the order
      # the engine vetted them (IPv4 first), and to no address it did not vet.
      # Each is given what is left of the entry's connect deadline, and the
      # walk stops when that is spent: the last error is raised, or
      # Net::OpenTimeout when the deadline ran out before an address was tried.
      # No bytes have been yielded when this moves on.
      def connected(vetted, budget)
        http = open_first(vetted.addresses.presence || [nil], vetted.uri, budget)
        yield http
      ensure
        http.finish if http&.started?
      end

      def open_first(addresses, uri, budget)
        last = nil
        addresses.each do |address|
          break if budget.spent?

          begin
            return dial(uri, address, budget)
          rescue *UNREACHABLE => e
            last = e
          end
        end
        raise last if last

        raise Net::OpenTimeout, "no time left to connect"
      end

      # One address, within what is left. Net::HTTP applies its open timeout to
      # the TCP connect and to the TLS handshake separately, so the pair is
      # also held to the one deadline here.
      def dial(uri, address, budget)
        http = Studio::ImageCache.pinned_http(uri, address)
        http.open_timeout = budget.left
        http.read_timeout = READ_TIMEOUT
        budget.spend { Timeout.timeout(budget.left, Net::OpenTimeout) { http.start } }
        http
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
