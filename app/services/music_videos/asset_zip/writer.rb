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
    class Writer
      Result = Data.define(:written, :missing)

      def initialize(manifest, fetcher: AssetZip.fetcher, logger: Rails.logger)
        @manifest = manifest
        @fetcher = fetcher
        @logger = logger
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
            # Not a known failure: say so in the log, and still finish the zip.
            @logger&.warn("[asset_zip] #{entry.path}: #{e.class}: #{e.message}")
            missing << Manifest::Missing.new(path: entry.path, label: entry.label, reason: "could not be read (#{e.class.name.demodulize})")
          end
        end
        write_text(zip, @manifest.readme_path, @manifest.readme(missing))
        Result.new(written: written + 1, missing: @manifest.missing + missing)
      end

      private

      def write_text(zip, path, text)
        zip.write_stored_file(path) { |sink| sink << text.to_s.b }
      end
    end
  end
end
