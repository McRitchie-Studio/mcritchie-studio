# The "Built with McRitchie Studio" gallery under the /build prompt: real apps a
# visitor can open, so the page shows what the App Builder delivers.
#
# Sources, in this order: the hand-kept list in config/build_examples.yml (apps
# live before /build existed), then every SHOWCASE request that is `live`, newest
# first. Only showcase requests: a customer's app is theirs, and listing it on a
# public page is not ours to decide.
module BuildGallery
  CONFIG = Rails.root.join("config/build_examples.yml")
  BLURB_LIMIT = 120

  # `image` is the card's dark-mode still; `motion` the short loop it plays on
  # hover (script/gallery_capture.cjs writes both). Either may be nil.
  # `palette` is the app's own theme for the card (#palette_for), or nil for
  # the Studio theme.
  Example = Struct.new(:name, :url, :emoji, :blurb, :image, :motion, :palette, keyword_init: true)

  # A palette's modes and the colours each must give (config `palettes`).
  PALETTE_MODES = %w[light dark].freeze
  PALETTE_KEYS = %w[surface primary name text].freeze
  HEX = /\A#\h{6}\z/

  IMAGE_DIR = "build_gallery".freeze

  module_function

  # Every app, the `lead` apps from the config first and in its order; the rest
  # keep their place (sort_by alone is not stable, hence the index).
  def examples
    lead = YAML.safe_load_file(CONFIG).fetch("lead", [])
    (configured + showcased).each_with_index
      .sort_by { |example, i| [ lead.index(subdomain(example.url)) || lead.size, i ] }
      .map(&:first)
  end

  # The config's `names` entry for a subdomain, else the subdomain titleized.
  def display_name(subdomain)
    names = YAML.safe_load_file(CONFIG).fetch("names", {}) || {}
    names[subdomain.to_s].presence || subdomain.to_s.tr("-", " ").titleize
  end

  # The config's `palettes` entry for a subdomain, as { "light" => {...},
  # "dark" => {...} }, or nil (the card keeps the Studio theme). Only a
  # complete entry of #rrggbb values counts: the card writes them into an
  # inline style, so nothing else may reach it.
  def palette_for(subdomain)
    entry = (YAML.safe_load_file(CONFIG).fetch("palettes", {}) || {})[subdomain.to_s]
    return nil unless entry.is_a?(Hash)

    palette = PALETTE_MODES.to_h { |mode| [ mode, (entry[mode] || {}).to_h.slice(*PALETTE_KEYS) ] }
    complete = palette.values.all? { |colours| PALETTE_KEYS.all? { |key| colours[key].to_s.match?(HEX) } }
    complete ? palette : nil
  end

  # "rantly" for https://rantly.mcritchie.studio.
  def subdomain(url)
    URI.parse(url.to_s).host.to_s.split(".").first
  rescue URI::InvalidURIError
    nil
  end

  def configured
    YAML.safe_load_file(CONFIG).fetch("examples", []).map do |attrs|
      Example.new(name: attrs.fetch("name"), url: attrs.fetch("url"), emoji: attrs["emoji"].presence || "🧱",
                  blurb: attrs["blurb"].to_s, image: existing_image(attrs["image"]), motion: existing_image(attrs["motion"]),
                  palette: palette_for(subdomain(attrs.fetch("url"))))
    end
  end

  def showcased
    AppRequest.where(showcase: true, status: "live").order(updated_at: :desc).map do |req|
      Example.new(name: display_name(req.subdomain), url: req.url, emoji: "🧱",
                  blurb: first_sentence(req.prompt), image: existing_image("#{IMAGE_DIR}/#{req.subdomain}.webp"),
                  motion: existing_image("#{IMAGE_DIR}/#{req.subdomain}.mp4"), palette: palette_for(req.subdomain))
    end
  end

  # An asset path (a still or a loop), or nil when the file is not there — a
  # card then shows its emoji, or just its still, instead of a broken file.
  def existing_image(path)
    return nil if path.blank?

    Rails.root.join("app/assets/images", path).file? ? path : nil
  end

  # The request's prompt is the only description it has; its first sentence,
  # bounded, reads as a caption.
  def first_sentence(text)
    sentence = text.to_s.strip.split(/(?<=[.!?])\s/).first.to_s
    sentence.truncate(BLURB_LIMIT, separator: " ")
  end
end
