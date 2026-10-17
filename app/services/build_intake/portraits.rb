module BuildIntake
  # The default CTO portraits a visitor picks from on the CTO card: twelve
  # ORIGINAL placeholder drawings (code-drawn SVGs, no licensed characters, no
  # image generation), one file per key under app/assets/images/cto_portraits/.
  #
  # THE KEY IS THE CONTRACT. app_requests.cto_avatar stores a key, never a file
  # name, so the real illustrated set can replace each file later without a
  # data change. An upload (chat media, a later task) is stored as
  # "upload:<ref>" instead and is not a key here.
  module Portraits
    KEYS = %w[sunrise harbor meadow ember glacier orchid canyon lagoon slate citrus dusk fern].freeze
    UPLOAD_PREFIX = "upload:".freeze

    module_function

    def key?(value) = KEYS.include?(value.to_s)

    def path(key) = key?(key) ? "cto_portraits/#{key}.svg" : nil

    def label(key) = key.to_s.capitalize

    # A stable default for a request: the same visitor sees the same first pick.
    def default_for(seed) = KEYS[seed.to_s.sum % KEYS.size]

    # Whether `value` may be stored as cto_avatar: a key, or an upload ref.
    def storable?(value)
      key?(value) || value.to_s.match?(/\A#{UPLOAD_PREFIX}[A-Za-z0-9_-]{8,100}\z/o)
    end
  end
end
