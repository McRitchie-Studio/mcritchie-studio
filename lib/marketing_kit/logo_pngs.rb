# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

module MarketingKit
  # Draws a kit's PNG logos from its SVGs (`bin/marketing-kit pngs DIR`), each
  # at the SVG's own shape: a horizontal logo comes out about ten times wider
  # than tall, never squared. script/brand_png.cjs draws squares only (an app's
  # favicon and icon), and a kit drawn with it got a padded square horizontal
  # logo. Full and horizontal logos are WIDE px wide at their own height; icons
  # are ICON px square, the mark fitted inside; the icon_512.png the quick-grab
  # set carries is drawn from icon_light.svg.
  # Headless Chrome renders, as it prints the guidelines PDF (ChromePdf).
  module LogoPngs
    WIDE = 2000
    ICON = 512

    module_function

    # The kit's logo names (SOP step 3 renames the hub's files to these).
    KIT_NAME = /\A(full|horizontal|icon)_(light|dark)\z/

    # [[svg path, png path, width, height]] for every kit-named logos/svg/*.svg
    # in dir; skipped lists any other SVG (a hub name not yet renamed, a
    # watermark), which gets no PNG rather than a guessed size.
    def plan(dir)
      svgs = Dir[File.join(dir, "logos", "svg", "*.svg")].sort
      svgs.select { |svg| File.basename(svg, ".svg").match?(KIT_NAME) }.flat_map do |svg|
        name = File.basename(svg, ".svg")
        width, height = name.start_with?("icon") ? [ICON, ICON] : size(File.read(svg), WIDE)
        png = ->(base) { File.join(dir, "logos", "png", "#{base}.png") }
        rows = [[svg, png.call(name), width, height]]
        rows << [svg, png.call("icon_512"), width, height] if name == "icon_light"
        rows
      end
    end

    def skipped(dir)
      Dir[File.join(dir, "logos", "svg", "*.svg")].sort.map { |svg| File.basename(svg) }
                                                  .reject { |base| File.basename(base, ".svg").match?(KIT_NAME) }
    end

    # The PNG size for an SVG drawn width px wide, its height following the
    # viewBox (Logos::PngSizes, the /logos downloads' own reader).
    def size(svg, width)
      Logos::PngSizes.fit(:width, width, *Logos::PngSizes.natural(svg))
    rescue ArgumentError => e
      raise Error, "cannot size the SVG: #{e.message}"
    end

    def draw(dir)
      rows = plan(dir)
      raise Error, "no kit-named SVGs (full_, horizontal_, icon_ + light or dark) in #{File.join(dir, 'logos', 'svg')}" if rows.empty?

      rows.each { |svg, png, width, height| render(svg, png, width, height) }
    end

    def render(svg, png, width, height)
      raise Error, "Chrome not found at #{ChromePdf::CHROME} (set CHROME_BIN)" unless File.executable?(ChromePdf::CHROME)

      FileUtils.mkdir_p(File.dirname(png))
      Dir.mktmpdir("kit-png") do |tmp|
        page = File.join(tmp, "logo.html")
        File.write(page, %(<!doctype html><html><body style="margin:0;background:transparent">) +
          %(<img src="file://#{File.expand_path(svg)}" style="display:block;width:#{width}px;height:#{height}px;object-fit:contain"></body></html>))
        out, status = Open3.capture2e(ChromePdf::CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                                      "--allow-file-access-from-files", "--default-background-color=00000000",
                                      "--window-size=#{width},#{height}", "--screenshot=#{File.expand_path(png)}",
                                      "file://#{page}")
        raise Error, "Chrome could not draw #{svg}:\n#{out}" unless status.success? && File.size?(png)
      end
      drawn = File.binread(png, 24)[16, 8].unpack("NN")
      raise Error, "#{png} came out #{drawn.join('x')}, not #{width}x#{height}" unless drawn == [width, height]

      png
    end
  end
end
