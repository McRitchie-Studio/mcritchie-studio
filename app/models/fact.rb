# One thing known about a subject (a person, a company or an app), with the
# document it came from. The value is encrypted at rest (Active Record
# Encryption, non-deterministic). A fact is refined, never edited: #supersede!
# writes a successor and links the predecessor to it; #retire! ends one.
#
# Identity data is never stored. A value that reads as an SSN, a card, an account
# or routing number, a passport or licence number, a PIN or a password is
# refused, and so is an unformatted number of LONG_NUMBER digits unless the key
# is a known numeric one (NUMERIC_KEYS). A key that names identity data takes a
# pointer: a fact with no value, only its source. The columns stored in the
# clear (key, subject slug, source reference, source note) pass the same screen.
#
# Sensitivity decides who reads and writes a fact through the API
# (Api::V1::FactsController): ordinary for a studio session, both for admin.
class Fact < ApplicationRecord
  SUBJECT_TYPES = %w[person company app].freeze
  SENSITIVITIES = %w[ordinary sensitive].freeze
  SOURCE_KINDS = %w[knowledge_doc drive_file].freeze
  SUBJECT_SLUG = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
  # A key is a name: lowercase words and digits joined by a hyphen or an underscore.
  KEY_FORMAT = /\A[a-z0-9]+(?:[-_][a-z0-9]+)*\z/
  KEY_MAX = 64
  KEY_MESSAGE = "is lowercase words and digits joined by a hyphen or an underscore, " \
                "#{KEY_MAX} characters at most (year-founded)".freeze
  POINTER = "store a pointer to the original instead".freeze
  POINTER_MESSAGE = "reads as identity data (%s); #{POINTER}: " \
                    "the same key with no value and the source that holds it".freeze
  KEY_POINTER_MESSAGE = "reads as identity data (%s); #{POINTER}: " \
                        "a key that only names it, no value, and the source that holds it".freeze

  # A key that names identity data, matched on the key in lowercase words.
  IDENTITY_KEY = /\b(ssn|social\ security|itin|password|passwd|pwd|passcode|passphrase|pin|
                  routing|aba|iban|cvv|cvc|passport|(?<!business\ )card|
                  acct|account(?!\ (manager|executive|rep|representative|team|owner))|
                  drivers?\ licen[cs]e|licen[cs]e\ (number|num|no|id)|secrets?|api\ keys?|private\ key|key\ ?pair|
                  seed\ phrase|wallet\ seed|mnemonic|recovery\ (phrase|key|codes?))\b/x
  # A person's tax id is their identity; a company's EIN is an ordinary fact.
  PERSON_IDENTITY_KEY = /\b(ein|fein|tin|tax\ (id|number|num|no)|taxpayer|licen[cs]e)\b/
  # What a text is refused for, by the kind the refusal names.
  IDENTITY_VALUE = {
    "ssn" => /(?<!\d)\d{3}[-. ]\d{2}[-. ]\d{4}(?!\d)|\b(ssn|social security)\b\D{0,12}\d{4,}/i,
    "routing number" => /\b(routing|aba)\b\D{0,12}\d{6,}/i,
    "account number" => /\b(account|acct|iban)\b\D{0,12}\d{6,}/i,
    "passport or licence number" => /\b(passport|licen[cs]e)\b\D{0,12}\d{6,}/i,
    "pin" => /\bpin\b\s*(is|[:=#])\s*\d{4,}/i,
    "password" => /\b(password|passwd|passcode|passphrase|pwd)\b\s*(is|[:=])\s*\S+/i,
    # A wallet's words (12 to 24 short lowercase words and nothing else), or a keypair's byte array.
    "seed phrase" => /\A\s*(?:[a-z]{3,8}\s+){11}(?:(?:[a-z]{3,8}\s+){3}){0,4}[a-z]{3,8}\s*\z/,
    "private key" => /\[\s*(?:\d{1,3}\s*,\s*){31,}\d{1,3}\s*\]|\b(seed phrase|mnemonic|private key|secret key)\b\s*(is|[:=])\s*\S+/i
  }.freeze
  CARD_CANDIDATE = /(?<!\d)\d(?:[ -]?\d){12,18}(?!\d)/
  # An unformatted run of this many digits reads as an account or id number.
  LONG_NUMBER = 8
  LONG_NUMBER_KIND = "an unformatted number of #{LONG_NUMBER} or more digits".freeze
  # An identity-named key carries fewer digits than a PIN has.
  IDENTITY_KEY_DIGITS = 4
  # The keys whose value may carry a long number, each with the runs it admits.
  NUMERIC_KEYS = [
    [/\b(phone|fax|tel|telephone|mobile|cell)\b/, /\A\d{10,15}\z/],
    [/\b(zip|postal)\b/, /\A\d{9}\z/],
    [/\b(date|founded|formed|incorporated|born|birthday|dob)\b/, /\A(19|20)\d{6}\z/]
  ].freeze
  # The same, for a company or an app only: public business identifiers.
  BUSINESS_NUMERIC_KEYS = [
    [/\b(ein|fein|tin|tax\ id|duns)\b/, /\A\d{9}\z/],
    [/\b(sos|entity)\ (id|number|no)\b|\bfile\ (number|no)\b/, /\A\d{8,12}\z/]
  ].freeze

  encrypts :value
  self.filter_attributes += %i[value]
  attr_readonly :slug, :subject_type, :key, :value, :sensitivity, :source_kind, :source_ref, :source_note,
                :recorded_by_session_slug, :recorded_at

  belongs_to :recorded_by_session, class_name: "AgentSession", foreign_key: :recorded_by_session_slug,
                                   primary_key: :slug, optional: true
  belongs_to :superseded_by, class_name: "Fact", foreign_key: :superseded_by_slug, primary_key: :slug, optional: true

  before_validation :assign_defaults, on: :create

  validates :slug, presence: true, uniqueness: true
  validates :subject_type, inclusion: { in: SUBJECT_TYPES }
  validates :subject_slug, format: { with: SUBJECT_SLUG }
  validates :key, presence: true
  validates :sensitivity, inclusion: { in: SENSITIVITIES }
  validates :source_kind, inclusion: { in: SOURCE_KINDS }
  validates :source_ref, presence: true, length: { maximum: 255 }
  validates :source_note, length: { maximum: 500 }
  validates :recorded_by_session_slug, :recorded_at, presence: true
  validate :person_subject_exists, on: :create
  validate :key_is_a_name, :value_or_pointer, :refuse_identity_data, on: :create

  scope :current, -> { where(superseded_by_slug: nil, retired_at: nil) }
  scope :for_subject, ->(type, slug) { where(subject_type: type.to_s, subject_slug: slug.to_s) }
  scope :readable_at, ->(tier) { tier.to_s == "admin" ? all : where(sensitivity: "ordinary") }
  scope :newest_first, -> { order(recorded_at: :desc, id: :desc) }

  # Is the encryption key set? False on a production app whose
  # ACTIVE_RECORD_ENCRYPTION_* config is missing; a read or write then raises
  # ActiveRecord::Encryption::Errors::Configuration.
  def self.encryption_ready?
    config = ActiveRecord::Encryption.config
    config.has_primary_key?.present? && config.has_key_derivation_salt?.present?
  end

  # The kind of identity data `text` reads as, or nil.
  def self.identity_kind(text)
    string = text.to_s.tr("_", " ")
    return nil if string.empty?

    kind = IDENTITY_VALUE.find { |_, pattern| pattern.match?(string) }&.first
    kind || ("card number" if string.scan(CARD_CANDIDATE).any? { |run| luhn?(run.delete("^0-9")) })
  end

  # [[fact, [the facts it replaced, nearest first]], ...] for every fact in
  # `facts` that nothing in `facts` supersedes, in the order given.
  def self.chains(facts)
    predecessor = facts.select(&:superseded?).index_by(&:superseded_by_slug)
    facts.reject { |fact| fact.superseded? && facts.any? { |other| other.slug == fact.superseded_by_slug } }.map do |head|
      chain = []
      at = head
      chain << at while (at = predecessor[at.slug]) && chain.exclude?(at)
      [head, chain]
    end
  end

  def self.luhn?(digits)
    sum = digits.reverse.each_char.with_index.sum do |char, index|
      n = char.to_i
      index.odd? ? (n * 2).digits.sum : n
    end
    (sum % 10).zero?
  end

  def identity_key?
    IDENTITY_KEY.match?(key_words) || (subject_type == "person" && PERSON_IDENTITY_KEY.match?(key_words))
  end

  def pointer? = value.blank?
  def sensitive? = sensitivity == "sensitive"
  def superseded? = superseded_by_slug.present?
  def retired? = retired_at.present?
  def current? = !superseded? && !retired?

  # Writes this fact's successor (same subject, key and, unless given,
  # sensitivity) and links this one to it. The predecessor keeps its own value
  # and source. A sensitivity given blank is refused: it would fall to the
  # default and demote a sensitive fact.
  def supersede!(recorded_by_session_slug:, **attrs)
    transaction do
      lock!
      refuse_settled!
      refuse_blank_sensitivity!(attrs)
      successor = self.class.create!(
        { subject_type: subject_type, subject_slug: subject_slug, key: key, sensitivity: sensitivity,
          source_kind: source_kind }.merge(attrs.compact).merge(recorded_by_session_slug: recorded_by_session_slug)
      )
      update!(superseded_by_slug: successor.slug)
      successor
    end
  end

  def retire!(now: Time.current)
    transaction do
      lock!
      refuse_settled!
      update!(retired_at: now)
    end
  end

  private

  def assign_defaults
    self.slug ||= "fact-#{SecureRandom.hex(8)}"
    self.key = key.to_s.strip
    self.sensitivity = sensitivity.presence || "ordinary"
    self.source_kind = source_kind.presence || "knowledge_doc"
    self.value = value.presence
    self.source_note = source_note.presence
    self.recorded_at ||= Time.current
  end

  def refuse_settled!
    return if current?

    errors.add(:base, superseded? ? "is superseded by #{superseded_by_slug}" : "is retired")
    raise ActiveRecord::RecordInvalid, self
  end

  def refuse_blank_sensitivity!(attrs)
    return if attrs[:sensitivity].nil? || attrs[:sensitivity].present?

    errors.add(:sensitivity, "can't be blank on a supersede: leave it out to keep #{sensitivity}, " \
                             "or name one of #{SENSITIVITIES.join(", ")}")
    raise ActiveRecord::RecordInvalid, self
  end

  def person_subject_exists
    return unless subject_type == "person" && subject_slug.present?

    errors.add(:subject_slug, "names no person") unless Person.exists?(slug: subject_slug)
  end

  def key_words = key.to_s.downcase.tr("_-", "  ")

  # The key is stored in the clear, so it names a thing and carries no data.
  def key_is_a_name
    return if key.blank?

    digits = key.count("0-9")
    kind = self.class.identity_kind(key)
    kind ||= LONG_NUMBER_KIND if digits >= LONG_NUMBER
    kind ||= "a number in a key that names it" if identity_key? && digits >= IDENTITY_KEY_DIGITS
    return errors.add(:key, format(KEY_POINTER_MESSAGE, kind)) if kind

    errors.add(:key, KEY_MESSAGE) unless key.length <= KEY_MAX && KEY_FORMAT.match?(key)
  end

  def value_or_pointer
    if identity_key?
      errors.add(:value, format(POINTER_MESSAGE, "the key names it")) unless pointer?
    elsif pointer?
      errors.add(:value, "can't be blank")
    end
  end

  def refuse_identity_data
    refuse(:value, self.class.identity_kind(value) || (LONG_NUMBER_KIND unless numbers_admitted?))
    refuse(:subject_slug, plain_kind(subject_slug, digits: subject_slug.to_s.count("0-9")))
    %i[source_ref source_note].each { |attribute| refuse(attribute, plain_kind(self[attribute])) }
  end

  def refuse(attribute, kind)
    errors.add(attribute, format(POINTER_MESSAGE, kind)) if kind && errors[attribute].empty?
  end

  # The kind a column stored in the clear is refused for, or nil.
  def plain_kind(text, digits: nil)
    long = digits ? digits >= LONG_NUMBER : long_numbers(text).any?
    self.class.identity_kind(text) || (LONG_NUMBER_KIND if long)
  end

  def long_numbers(text) = text.to_s.scan(/\d{#{LONG_NUMBER},}/)

  # Does the key admit every long number the value carries?
  def numbers_admitted?
    rules = NUMERIC_KEYS + (subject_type == "person" ? [] : BUSINESS_NUMERIC_KEYS)
    admitted = rules.select { |words, _| words.match?(key_words) }.map(&:last)
    long_numbers(value).all? { |run| admitted.any? { |shape| shape.match?(run) } }
  end
end
