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

  Example = Struct.new(:name, :url, :emoji, :blurb, :image, keyword_init: true)

  IMAGE_DIR = "build_gallery".freeze

  module_function

  def examples = configured + showcased

  def configured
    YAML.safe_load_file(CONFIG).fetch("examples", []).map do |attrs|
      Example.new(name: attrs.fetch("name"), url: attrs.fetch("url"), emoji: attrs["emoji"].presence || "🧱",
                  blurb: attrs["blurb"].to_s, image: existing_image(attrs["image"]))
    end
  end

  def showcased
    AppRequest.where(showcase: true, status: "live").order(updated_at: :desc).map do |req|
      Example.new(name: req.subdomain.to_s.tr("-", " ").titleize, url: req.url, emoji: "🧱",
                  blurb: first_sentence(req.prompt), image: existing_image("#{IMAGE_DIR}/#{req.subdomain}.jpg"))
    end
  end

  # An image path for image_tag, or nil when the file is not there — a card
  # then shows its emoji instead of a broken image.
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
