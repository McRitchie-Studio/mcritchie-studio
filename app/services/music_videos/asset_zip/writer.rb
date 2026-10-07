# frozen_string_literal: true

module MusicVideos
  module AssetZip
    # Walks a Manifest into a ZipKit::Streamer, one entry at a time, each
    # stored (no compression: MP4, JPG and PNG are already compressed, and
    # deflating 300 MB would cost a dyno CPU for nothing) and streamed from
    # its Fetcher with a data descriptor, so no size is needed up front and
    # no file is held whole.
    #
    # An entry that cannot be read never fails the zip: zip_kit rolls the
    # half-written entry out of the central directory, and the README lists
    # it. The README goes last, because only then is that list known.
    #
    # A CLIENT THAT GOES AWAY stops the zip at once. The body is written by
    # Puma inside body.each, so a write to a closed socket raises
    # Puma::ConnectionError back up through the sink (proved over a real
    # socket: test/integration/asset_zip_client_disconnect_test.rb). It is
    # re-raised, never skipped: skipping would start an R2 or HTTP fetch for
    # every remaining file, each aborting on the dead socket while the Puma
    # thread stays busy. Unwinding closes the open read (Net::HTTP.start and
    # the SDK's session pool both finish their socket on an error) and Puma
    # swallows the error. It is not an error, so it is never logged as one.
    #
    # Any other failure nobody named (not a FetchFailed) is recorded in
    # ErrorLog once per download, the first one, since the route is admin
    # only and the Rails log alone is where nobody looks.
    class Writer
      Result = Data.define(:written, :missing)

      # Whether this error (or what it wraps) is the client having gone away.
      def self.client_gone?(error)
        seen = 0
        while error && seen < 5
          return true if defined?(::Puma::ConnectionError) && error.is_a?(::Puma::ConnectionError)

          error = error.cause
          seen += 1
        end
        false
      end

      def initialize(manifest, fetcher: AssetZip.fetcher, logger: Rails.logger)
        @manifest = manifest
        @fetcher = fetcher
        @logger = logger
        @recorded = false
      end

      def write(zip)
        missing = []
        written = 0
        @manifest.entries.each do |entry|
          begin
            if entry.kind == :text
              write_text(zip, entry.path, entry.source)
            else
              zip.write_stored_file(entry.path) { |sink| @fetcher.each_chunk(entry) { |bytes| sink << bytes } }
            end
            written += 1
          rescue FetchFailed => e
            missing << Manifest::Missing.new(path: entry.path, label: entry.label, reason: e.message)
          rescue StandardError => e
            if self.class.client_gone?(e)
              @logger&.info("[asset_zip] #{@manifest.filename}: the client went away after #{written} of " \
                            "#{@manifest.entries.size} files; stopped")
              raise
            end
            # Not a known failure: say so in the log, and still finish the zip.
            @logger&.warn("[asset_zip] #{entry.path}: #{e.class}: #{e.message}")
            record(e)
            missing << Manifest::Missing.new(path: entry.path, label: entry.label, reason: "could not be read (#{e.class.name.demodulize})")
          end
        end
        write_text(zip, @manifest.readme_path, @manifest.readme(missing))
        Result.new(written: written + 1, missing: @manifest.missing + missing)
      rescue StandardError => e
        # A failure that ends the stream itself (the README, the zip): it
        # still propagates, as before, so the download is cut short.
        record(e) unless self.class.client_gone?(e)
        raise
      end

      private

      def write_text(zip, path, text)
        zip.write_stored_file(path) { |sink| sink << text.to_s.b }
      end

      # The first failure of this download into ErrorLog; never fails the zip.
      def record(error)
        return if @recorded

        @recorded = true
        log = ErrorLog.capture!(error)
        log.target = @manifest.alt_video
        log.target_name = @manifest.filename
        log.save!
      rescue StandardError => e
        @logger&.warn("[asset_zip] could not record #{error.class} in ErrorLog: #{e.class}: #{e.message}")
      end
    end
  end
end
