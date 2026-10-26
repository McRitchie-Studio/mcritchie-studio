# frozen_string_literal: true

require "zip_kit"

# A BRAND'S KIT AS FILES (task kit-export-and-clear-lens; Alex McRitchie 2026-10-12 00:55: his Commercial Welding site drew an old
# copy of the navbar, not the one his kit saves). An app takes its logo from here, never from a hand-made copy:
#
#   /logos/:brand/kit.zip                 every file below plus a README, in one download
#   /logos/:brand/kit/navbar-dark.svg     one file, always the CURRENT kit choice (FILES names them all)
#
# Each file is what the brand page's Kit card shows (BrandKit#variant): the saved Icon, Navbar Logo and Stacked Logo,
# each drawing the kit's icon, or the brand's default for a type nothing is saved for, in each tone: light (for a light
# background), dark (for a dark one) and watermark (one colour, slightly transparent). The README says what each file
# is, which are saved and which default, the palette and typefaces, and who saved the kit when.
#
# Admin only, like the rest of /logos: a person downloads it, or an app's build fetches it with an admin's signed-in
# session (docs/topics/logos.md, "How an app takes its logo from the kit").
class BrandKitExport
  # "icon-light.svg" => [:icon, :light], in the order the README and the zip list them.
  FILES = BrandKit::CHOICE_TYPES.product(Logos::NavbarLogo::TONES).to_h { |type, tone| ["#{type}-#{tone}.svg", [type, tone]] }.freeze
  TONE_USES = { light: "for a light background", dark: "for a dark background", watermark: "one colour, slightly transparent" }.freeze

  attr_reader :kit, :brand

  # `kit` is the brand's BrandKit, saved or not; `base_url` makes the README's links absolute (the request's, so a
  # desk's README names the desk). `saver` is the name of the person who saved it last, when known.
  def initialize(kit, base_url:, saver: nil)
    @kit = kit
    @brand = kit.brand
    @base_url = base_url.to_s.chomp("/")
    @saver = saver
  end

  def self.file?(name) = FILES.key?(name.to_s)

  # One file's Logos::Variant. A name not in FILES is an Error; so is a logo the brand's data cannot draw.
  def variant(name)
    type, tone = FILES.fetch(name.to_s) { raise BrandKit::Error, "unknown kit file #{name.to_s.inspect[0, 60]}: expected one of #{FILES.keys.join(', ')}" }
    kit.variant(type, tone:)
  end

  def svg(name) = variant(name).svg

  # Every file the kit draws, by name, and the ones it cannot draw, by name, with why.
  def drawings
    @drawings ||= FILES.keys.each_with_object({ drawn: {}, refused: {} }) do |name, out|
      out[:drawn][name] = variant(name)
    rescue BrandKit::Error => e
      out[:refused][name] = e.message
    end
  end

  def zip_filename = "#{brand}-kit.zip"
  def folder = "#{brand}-kit"

  # The zip's bytes: one folder holding the README and every drawn file.
  def zip
    io = StringIO.new("".b)
    ZipKit::Streamer.open(io) do |zip|
      zip.write_deflated_file("#{folder}/README.md") { |sink| sink << readme.b }
      drawings[:drawn].each { |name, variant| zip.write_deflated_file("#{folder}/#{name}") { |sink| sink << variant.svg.b } }
    end
    io.string
  end

  def readme
    style = Logos::BrandKit.new(brand)
    title = Logos::Variant.brand_name(Logos::NavbarLogo.new(brand))
    lines = ["# #{title}: logo kit", "", saved_line, "", "Brand page: #{@base_url}/logos/#{brand}", "", "## Files", "",
             "| File | Kit | What it is |", "|------|-----|------------|"]
    drawings[:drawn].each do |name, variant|
      type, tone = FILES.fetch(name)
      lines << "| #{name} | #{kit.saved?(type) ? 'saved' : 'default'} | #{variant.label} (#{TONE_USES.fetch(tone)}) |"
    end
    drawings[:refused].each { |name, why| lines << "| #{name} | not drawn | #{why.tr('|', '/')} |" }
    lines += ["", "\"saved\" is the operator's saved kit choice; \"default\" is the brand's default, shown while nothing is saved for that logo.",
              "", "## Palette", ""] + style.palette.map { |swatch| "- #{swatch.name} #{swatch.hex}" }
    lines += ["", "## Typefaces", ""] + style.typefaces.map { |face| "- #{face.role}: #{face.name}" }
    lines += ["", "## Stable URLs", "", "Each always serves the current kit choice (admin sign-in required):", ""]
    lines += FILES.keys.map { |name| "- #{@base_url}/logos/#{brand}/kit/#{name}" }
    lines += ["- #{@base_url}/logos/#{brand}/kit.zip (this whole kit)", ""]
    lines.join("\n")
  end

  private

  def saved_line
    saved = kit.persisted? && BrandKit::CHOICE_TYPES.any? { |type| kit.saved?(type) }
    return "Nothing saved yet: every file is the brand's default." unless saved

    who = @saver.presence || kit.updated_by.to_s.split("@").first.presence
    "Kit saved #{kit.updated_at.utc.strftime('%Y-%m-%d %H:%M UTC')}#{" by #{who}" if who}."
  end
end
