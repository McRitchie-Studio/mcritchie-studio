# The optional "key method" of a unit of work — the ONE load-bearing call worth
# copying out of the trail (e.g. `User.find_by(email: ...)`, `bin/release prepare
# --yes`). Shared by AtomicEvent (agent-provided at span close) and AtomicAction
# (hook-derived from a bash command). The UI renders it as a chip with a leading
# LANGUAGE badge + a copy button, so `key_method_lang` is normalized here: an
# explicit lang always wins; a blank one is inferred from the code's shape.
#
# Everything is optional and telemetry-adjacent, so normalization never raises:
# values are trimmed to caps rather than failing validation.
module HasKeyMethod
  extend ActiveSupport::Concern

  MAX_KEY_METHOD_LENGTH = 500
  MAX_LANG_LENGTH       = 20

  # The inference ladder, most-specific first. `bash` is the terminal default —
  # this trail is overwhelmingly shell commands, so unrecognized code reads as one.
  LANG_PATTERNS = [
    ["sql",  /\A\s*(select|insert|update|delete|alter|create\s+(table|index|view))\b/i],
    ["js",   /\b(const |let |=> |await |document\.|console\.)/],
    ["ruby", /::|\b[A-Z][A-Za-z0-9_]*\.\w+|\.\w+\((\w+:|\s*&:)|\bdo \|/]
  ].freeze
  DEFAULT_LANG = "bash"

  included do
    before_validation :normalize_key_method
  end

  # Pure + unit-testable: the badge language for a snippet, or nil for blank code.
  def self.infer_lang(code)
    text = code.to_s.strip
    return nil if text.empty?

    LANG_PATTERNS.each { |lang, pattern| return lang if pattern.match?(text) }
    DEFAULT_LANG
  end

  # Pure: { key_method:, key_method_lang: } trimmed to caps with the lang inferred
  # when blank, or BOTH nil for blank code (the pair travels together). Shared by
  # the before_validation below and callback-skipping writers (update_all closes).
  def self.normalize_pair(code, lang)
    key = code.to_s.strip.presence&.first(MAX_KEY_METHOD_LENGTH)
    return { key_method: nil, key_method_lang: nil } if key.nil?

    { key_method: key,
      key_method_lang: lang.to_s.strip.downcase.presence&.first(MAX_LANG_LENGTH) || infer_lang(key) }
  end

  private

  def normalize_key_method
    assign_attributes(HasKeyMethod.normalize_pair(key_method, key_method_lang))
  end
end
