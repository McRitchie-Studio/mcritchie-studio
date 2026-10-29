# frozen_string_literal: true

require_relative "brand_kit"

module Logos
  # A brand's TYPE SCALE (task brand-kit-type-scale): every text size a design uses, as a multiple of one base, the
  # method of the font-sizing reel Alex McRitchie sent on 2026-10-28 (instagram.com/reel/DeovSkExOpE). Title 6x,
  # heading 3x, subhead 1.5x, body 1x, fine print 3/4x. The multiples are the brand kit's; the base is the surface's:
  # 24 px on a 1080-wide social post (the reel's minimum body size) and 16 px on the web. Sizes round to whole pixels.
  #
  # Each role is set in a face from the brand's typefaces (Logos::BrandKit): the title and heading in its first level
  # that has a font, the rest in its Text level, or else its last level with a font. Traced lettering has no font to set.
  #
  #   scale = Logos::TypeScale.new(Logos::BrandKit.new("studio"))
  #   scale.surfaces.first.sizes.first   # => #<data Size role=…Title, px=144>
  #   scale.roles.first.typeface.name    # => "Montserrat ExtraBold"
  class TypeScale
    Role = Data.define(:key, :label, :multiple, :typeface) do
      # The multiple as the scale names it: "6x", "1.5x", "3/4x".
      def multiple_label = multiple == 0.75 ? "3/4x" : "#{multiple.to_s.delete_suffix('.0')}x"
    end

    Size = Data.define(:role, :px)

    Surface = Data.define(:key, :label, :base, :sizes) do
      def token_prefix(brand) = key == "web" ? "--#{brand}-text" : "--#{brand}-#{key}-text"
    end

    # [key, label, multiple, face]: face :display or :text picks the typeface, as above.
    ROLES = [
      ["title", "Title", 6, :display],
      ["heading", "Heading", 3, :display],
      ["subhead", "Subhead", 1.5, :text],
      ["body", "Body", 1, :text],
      ["fine-print", "Fine print", 0.75, :text]
    ].freeze

    # [key, label, base px]
    SURFACES = [
      ["social", "Social post, 1080 wide", 24],
      ["web", "Web", 16]
    ].freeze

    attr_reader :brand, :roles, :surfaces

    def initialize(kit)
      @brand = kit.brand
      fonted = kit.typefaces.reject(&:traced?)
      faces = { display: fonted.first, text: fonted.find { |face| face.role == "Text" } || fonted.last }
      @roles = ROLES.map { |key, label, multiple, face| Role.new(key:, label:, multiple:, typeface: faces.fetch(face)) }.freeze
      @surfaces = SURFACES.map do |key, label, base|
        Surface.new(key:, label:, base:, sizes: roles.map { |role| Size.new(role:, px: (base * role.multiple).round) }.freeze)
      end.freeze
    end

    # The scale as CSS custom properties, one block: --<brand>-text-<role> for the web, --<brand>-social-text-<role>.
    def css
      lines = surfaces.flat_map do |surface|
        surface.sizes.map { |size| "  #{surface.token_prefix(token)}-#{size.role.key}: #{size.px}px;" }
      end
      ":root {\n#{lines.join("\n")}\n}\n"
    end

    private

    def token = brand.downcase.gsub(/[^a-z0-9]+/, "-").delete_prefix("-").delete_suffix("-")
  end
end
