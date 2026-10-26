# frozen_string_literal: true

require "json"
require "zlib"

# PrecompressedAssets: the .gz sidecars Sprockets used to write beside each
# compiled asset, written for Propshaft, which writes none.
#
# Production serves public/assets through ActionDispatch::Static, which Rack::Deflater
# sits INSIDE (config/application.rb), so a static file is never compressed per
# request. What the hub sends compressed is what FileHandler finds as a sidecar:
# for a compressible type (text/*, application/javascript, image/svg+xml) and a
# client that accepts gzip, it serves <file>.gz in place of <file>. Without these,
# every stylesheet, script and SVG would go out at full size.
#
# Run after assets:precompile (lib/tasks/precompressed_assets.rake). Only the files
# the Propshaft manifest names are compressed, so a stale file left in
# public/assets from an earlier build is not, and a sidecar whose file is gone
# (assets:clean removed it) is deleted.
class PrecompressedAssets
  # The extensions FileHandler would serve compressed. A .gz of anything else
  # (a PNG, an AVIF, a font) is never read, so it is never written.
  EXTENSIONS = %w[.css .js .svg].freeze

  def initialize(output_path)
    @output_path = Pathname(output_path)
  end

  # Writes a sidecar for every manifest file that lacks a current one, prunes
  # orphans, and answers the sidecars it wrote.
  def write!
    written = digested_paths.filter_map do |relative|
      source = @output_path.join(relative)
      next unless source.file? && EXTENSIONS.include?(source.extname)

      gz = Pathname("#{source}.gz")
      next if gz.file? && gz.mtime >= source.mtime

      Zlib::GzipWriter.open(gz.to_s, Zlib::BEST_COMPRESSION) do |out|
        out.mtime = source.mtime.to_i
        out.orig_name = source.basename.to_s
        out.write(source.binread)
      end
      gz
    end
    prune!
    written
  end

  # Deletes every .gz under the output path whose source file is gone.
  def prune!
    Dir.glob(@output_path.join("**/*.gz").to_s).each do |gz|
      File.delete(gz) unless File.file?(gz.delete_suffix(".gz"))
    end
  end

  private
    def digested_paths
      manifest = @output_path.join(".manifest.json")
      return [] unless manifest.file?

      JSON.parse(manifest.read).values.map { |entry| entry.is_a?(Hash) ? entry["digested_path"] : entry }.compact
    end
end
