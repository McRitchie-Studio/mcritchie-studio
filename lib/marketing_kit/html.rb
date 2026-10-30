# frozen_string_literal: true

require "erb"
require "base64"

module MarketingKit
  # Small HTML helpers shared by the renderers. Google Docs import keeps inline
  # styles and drops stylesheets, so every Doc-bound tag carries its own style.
  module Html
    module_function

    def h(text) = ERB::Util.html_escape(text.to_s)

    def file_url(path) = "file://#{ERB::Util.url_encode(path).gsub('%2F', '/')}"

    # Google Docs import keeps an image only when it is inline data.
    def data_uri(path)
      mime = { ".png" => "image/png", ".jpg" => "image/jpeg", ".jpeg" => "image/jpeg", ".svg" => "image/svg+xml" }
             .fetch(File.extname(path).downcase) { raise Error, "unsupported image #{path}" }
      "data:#{mime};base64,#{Base64.strict_encode64(File.binread(path))}"
    end

    def rgb(hex) = hex.delete("#").scan(/../).map { |p| p.to_i(16) }.join(", ")

    # Perceived brightness, 0-255: text on a swatch above about 150 reads dark.
    def light?(hex)
      r, g, b = hex.delete("#").scan(/../).map { |p| p.to_i(16) }
      (r * 299 + g * 587 + b * 114) / 1000 > 150
    end

    def table(head, rows)
      cells = ->(tag, row) { row.map { |c| "<#{tag}>#{c}</#{tag}>" }.join }
      "<table><tr>#{cells.call('th', head)}</tr>#{rows.map { |r| "<tr>#{cells.call('td', r)}</tr>" }.join}</table>"
    end

    # Brands a Doc-bound HTML fragment: inline styles on the tags Google Docs
    # keeps, and the tagline under the first heading.
    class DocStyler
      def initialize(spec)
        @spec = spec
      end

      def page(body)
        font = "font-family:#{family}"
        body = body.sub(%r{</h1>}) { "</h1>#{tagline}" }
        styles.each { |tag, style| body = body.gsub("<#{tag}>", "<#{tag} style=\"#{style}\">") }
        body = body.gsub("<b>", "<b style=\"color:#{c(:primary)}\">")
        "<html><head><meta charset=\"utf-8\"></head><body style=\"#{font}\">#{body}</body></html>"
      end

      private

      def c(key) = @spec.colour(key)
      def family = "#{@spec.fonts[:family]},#{@spec.fonts[:fallback]},sans-serif"

      def tagline
        "<p style=\"font-family:#{family};font-weight:#{@spec.fonts[:subhead]};color:#{c(:accent)};letter-spacing:2px;" \
          "font-size:10pt;margin-top:0\">#{Html.h(@spec.tagline.delete_suffix('.').upcase)}</p>"
      end

      def styles
        f = "font-family:#{family}"
        heading = "font-family:'#{@spec.fonts[:family]} ExtraBold',#{family};font-weight:#{@spec.fonts[:heading]};color:#{c(:title)}"
        {
          "h1" => "#{heading};font-size:24pt;margin-bottom:2pt",
          "h2" => "#{heading};font-size:15pt",
          "h3" => "#{f};font-weight:#{@spec.fonts[:subhead]};color:#{c(:accent)};font-size:12pt",
          "p" => "#{f};font-size:10.5pt;color:#1F2933",
          "li" => "#{f};font-size:10.5pt;color:#1F2933",
          "th" => "#{f};font-weight:700;background-color:#{c(:primary)};color:#FFFFFF;border:1px solid #{c(:primary)};" \
                  "padding:5px;text-align:left;font-size:10pt",
          "td" => "#{f};font-size:10pt;color:#1F2933;border:1px solid #C9D6E3;padding:5px"
        }
      end
    end
  end
end
