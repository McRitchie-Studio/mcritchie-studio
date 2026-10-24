module BuildIntake
  # The twelve ORIGINAL placeholder portraits the CTO card offered before the
  # animal bank (BuildIntake::Animals, task cto-animal-avatar-bank): code-drawn
  # SVGs, one file per key under app/assets/images/cto_portraits/. The card now
  # offers animals; these keys stay valid and keep rendering for every draft
  # and app that chose one.
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

    # Whether a visitor may pick `value` on the CTO card or in the CTO chat's
    # picker: an animal from the bank, or a portrait key (kept for the apps
    # that already hold one).
    def choosable?(value) = key?(value) || Animals.avatar?(value)

    # Whether `value` may be stored as cto_avatar: a choosable avatar, or an upload ref.
    def storable?(value)
      choosable?(value) || value.to_s.match?(/\A#{UPLOAD_PREFIX}[A-Za-z0-9_-]{8,100}\z/o)
    end
  end
end
