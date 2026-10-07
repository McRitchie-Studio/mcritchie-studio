# frozen_string_literal: true

require "fileutils"

module EmailImages
  # WHAT A BRAND'S HEADERS ARE MADE FROM, as files an agent can open and show
  # Alex before a round (the `email-image` SOP, step 1): the kit's reference
  # images (mascot or logo, style anchor), its palette, its style words, and the
  # headers already approved for that brand.
  #
  # References live in this repo under public/, so they are copied (a WebP is
  # converted to PNG so any viewer opens it); approved headers are read from our
  # bucket. Each comes back with its public URL too: on a one-off production dyno
  # (`heroku run`) the local files vanish with the dyno, and the agent fetches
  # the URLs instead.
  class BaseAssets
    Item = Struct.new(:kind, :role, :label, :path, :url, :source, :note, :origin, keyword_init: true)

    VIEWABLE = %w[jpg png].freeze

    def self.call(kit, **kwargs) = new(kit, **kwargs).call

    def initialize(kit, out:, download: true, base_url: EmailImages::BaseAssets.base_url)
      @kit = kit
      @out = File.expand_path(out.to_s)
      @download = download
      @base_url = base_url.to_s.chomp("/")
    end

    def call
      FileUtils.mkdir_p(@out) if @download
      references + [palette_swatch] + approved_headers
    end

    # The hub's own public origin: https://mcritchie.studio in production
    # (APP_HOST), http://localhost:<port> in development.
    def self.base_url
      opts = Rails.application.config.action_mailer.default_url_options || {}
      host = opts[:host].presence || "localhost"
      protocol = opts[:protocol].presence || (host == "localhost" ? "http" : "https")
      port = opts[:port].present? ? ":#{opts[:port]}" : ""
      "#{protocol}://#{host}#{port}"
    end

    private

    # The kit's merged references (EmailImages::BrandKit#references): the YAML
    # ones from public/, then the active uploads from our bucket, newest first,
    # each with its role, label and the admin's note on how to use it.
    def references
      @kit.references.map do |ref|
        if ref.yaml?
          Item.new(kind: "reference", role: ref.role, label: ref.label, source: ref.path, origin: "yaml",
                   url: "#{@base_url}#{ref.display_url}",
                   path: (copy_reference(ref) if @download && ref.exists?))
        else
          Item.new(kind: "reference", role: ref.role, label: ref.label, source: ref.source, origin: "upload",
                   note: ref.note, url: ref.url,
                   path: (fetch_to_file(ref.url, "#{ref.role}-#{ref.slug}") if @download))
        end
      end
    end

    # The palette as one strip of colour blocks, in the kit's order, so Alex
    # sees the colours rather than reads hex. Local only (no public URL).
    def palette_swatch
      label = @kit.palette.map { |name, hex| "#{name} #{hex}" }.join(", ")
      Item.new(kind: "palette", role: "swatch", label: label, source: "config/email_brand_kits.yml",
               url: nil, path: (write_swatch if @download && @kit.palette.any?))
    end

    def write_swatch
      path = File.join(@out, "palette-#{@kit.key}.png")
      MiniMagick.convert do |c|
        c.size "160x160"
        @kit.palette.each_value { |hex| c << "xc:#{hex}" }
        c << "+append"
        c << path
      end
      path
    rescue MiniMagick::Error
      nil
    end

    # Every brief of this brand whose header Alex approved: the house look so
    # far, and the natural style anchor for the next one.
    def approved_headers
      briefs = EmailImageBrief.where(brand_kit: @kit.key).where.not(approved_artifact_slug: nil).ordered
      briefs.filter_map do |brief|
        artifact = brief.approved_artifact
        next unless artifact&.approved?

        Item.new(kind: "approved", role: brief.catalog_key, label: brief.headline, source: brief.slug,
                 url: artifact.image_url, path: (fetch_to_file(artifact.image_url, "approved-#{brief.slug}") if @download))
      end
    end

    def copy_reference(ref)
      bytes = File.binread(ref.absolute_path)
      write_viewable(bytes, "#{ref.role}-#{File.basename(ref.path, '.*')}")
    end

    def fetch_to_file(url, name)
      write_viewable(EmailImages::Download.bytes(url), name)
    rescue EmailImages::Download::Failed
      nil
    end

    # JPG and PNG are written as they are; anything else (the gator is a WebP)
    # is converted to PNG with MiniMagick so every image viewer opens it.
    def write_viewable(bytes, name)
      ext = EmailImages::Download.extension_for(bytes, default: "png")
      unless VIEWABLE.include?(ext)
        image = MiniMagick::Image.read(bytes)
        image.format("png")
        bytes = image.to_blob
        ext = "png"
      end
      path = File.join(@out, "#{name}.#{ext}")
      File.binwrite(path, bytes)
      path
    end
  end
end
