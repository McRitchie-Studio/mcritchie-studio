# frozen_string_literal: true

require_relative "brand_kit"

module Logos
  # A brand's TYPE SCALE (task brand-kit-type-scale): every text size a design uses, as a multiple of one base, the
  # method of the font-sizing reel Alex McRitchie sent on 2026-10-28 (instagram.com/reel/DeovSkExOpE). Title 6x,
  # heading 3x, subhead 1.5x, body 1x, fine print 3/4x. The multiples are the brand kit's; the base is the surface's:
  # 24 px on a 1080-wide social post (the reel's minimum body size), 16 px on an app's public pages and 14 px on its
  # admin and ops pages (Alex McRitchie's option B, 2026-10-28). Sizes round to the half pixel: the dense fine print is
  # 10.5 px, as the engine draws it.
  #
  # The scale is the standard for every app (task brand-kit-carries-type-scale): studio-engine draws the same roles as
  # its type-* utilities, and `engine_settings` are the four Studio.type_* settings an app takes from its brand kit,
  # carried in kit.json (BrandKitInstall) and set by the brand-kit-rollout SOP.
  #
  # Each role is set in a face from the brand's typefaces (Logos::BrandKit): the title and heading in its first level
  # that has a font, the rest in its Text level, or else its last level with a font. Traced lettering has no font to
  # set; a brand with no font at all takes FALLBACK, the engine's own Montserrat Regular.
  #
  #   scale = Logos::TypeScale.new(Logos::BrandKit.new("studio"))
  #   scale.surfaces.first.sizes.first   # => #<data Size role=…Title, px=144>
  #   scale.roles.first.typeface.name    # => "Montserrat ExtraBold"
  #   scale.engine_settings              # => {"type_base"=>16, "type_dense_base"=>14, "type_display_weight"=>800, ...}
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

    # [key, label, base px]. "web" is an app's public pages (Studio.type_base); "dense" its admin and ops pages, inside
    # the engine's type-dense container (Studio.type_dense_base).
    SURFACES = [
      ["social", "Social post, 1080 wide", 24],
      ["web", "Web", 16],
      ["dense", "Admin & ops", 14]
    ].freeze

    FALLBACK = BrandKit::Typeface.new(role: "Text", family: "Montserrat", weight: 400, label: nil)

    attr_reader :brand, :roles, :surfaces

    def initialize(kit)
      @brand = kit.brand
      fonted = kit.typefaces.reject(&:traced?)
      faces = { display: fonted.first || FALLBACK, text: fonted.find { |face| face.role == "Text" } || fonted.last || FALLBACK }
      @roles = ROLES.map { |key, label, multiple, face| Role.new(key:, label:, multiple:, typeface: faces.fetch(face)) }.freeze
      @surfaces = SURFACES.map do |key, label, base|
        Surface.new(key:, label:, base:, sizes: roles.map { |role| Size.new(role:, px: px(base * role.multiple)) }.freeze)
      end.freeze
    end

    # The four studio-engine settings an app takes from this kit (studio-engine README "Type scale"), as kit.json
    # carries them: the public and dense bases, the title's weight and the body's.
    def engine_settings
      bases = surfaces.to_h { |surface| [surface.key, surface.base] }
      { "type_base" => bases.fetch("web"), "type_dense_base" => bases.fetch("dense"),
        "type_display_weight" => role("title").typeface.weight, "type_text_weight" => role("body").typeface.weight }
    end

    # The settings as the lines an app's config/initializers/studio.rb takes.
    def initializer = engine_settings.map { |name, value| "Studio.#{name} = #{value}" }.join("\n") + "\n"

    # The scale as CSS custom properties, one block: --<brand>-text-<role> for the web, --<brand>-<surface>-text-<role>
    # for the others.
    def css
      lines = surfaces.flat_map do |surface|
        surface.sizes.map { |size| "  #{surface.token_prefix(token)}-#{size.role.key}: #{size.px}px;" }
      end
      ":root {\n#{lines.join("\n")}\n}\n"
    end

    def role(key) = roles.find { |role| role.key == key }

    private

    def px(size)
      half = (size * 2).round / 2.0
      half == half.round ? half.round : half
    end

    def token = brand.downcase.gsub(/[^a-z0-9]+/, "-").delete_prefix("-").delete_suffix("-")
  end
end
