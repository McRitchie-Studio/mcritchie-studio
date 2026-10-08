# One thing known about a subject (a person, a company or an app), with the
# document it came from. The value is encrypted at rest (Active Record
# Encryption, non-deterministic). A fact is refined, never edited: #supersede!
# writes a successor and links the predecessor to it; #retire! ends one.
#
# Identity data is never stored. A value or a source note that reads as an SSN, a
# card, an account or routing number, or a password is refused, and a key that
# names one of those takes a pointer: a fact with no value, only its source.
#
# Sensitivity decides who reads and writes a fact through the API
# (Api::V1::FactsController): ordinary for a studio session, both for admin.
class Fact < ApplicationRecord
  SUBJECT_TYPES = %w[person company app].freeze
  SENSITIVITIES = %w[ordinary sensitive].freeze
  SOURCE_KINDS = %w[knowledge_doc drive_file].freeze
  SUBJECT_SLUG = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
  POINTER_MESSAGE = "reads as identity data (%s); store a pointer to the original instead: " \
                    "the same key with no value and the source that holds it".freeze

  # A key that names identity data, matched on the key in lowercase words.
  IDENTITY_KEY = /\b(ssn|social\ security|password|passcode|passphrase|routing|aba|iban|cvv|cvc|pin|
                  (account|acct|card)\ (number|num|no)|(credit|debit)\ card)\b/x
  # What a value is refused for, by the kind the refusal names.
  IDENTITY_VALUE = {
    "ssn" => /(?<!\d)\d{3}[- ]\d{2}[- ]\d{4}(?!\d)|\b(ssn|social security)\b\D{0,12}\d{4,}/i,
    "routing number" => /\b(routing|aba)\b\D{0,12}\d{6,}/i,
    "account number" => /\b(account|acct|iban)\b\D{0,12}\d{6,}/i,
    "password" => /\b(password|passcode|passphrase|pwd)\b\s*(is|[:=])\s*\S+/i
  }.freeze
  CARD_CANDIDATE = /(?<!\d)\d(?:[ -]?\d){12,18}(?!\d)/

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
  validates :key, presence: true, length: { maximum: 120 }
  validates :sensitivity, inclusion: { in: SENSITIVITIES }
  validates :source_kind, inclusion: { in: SOURCE_KINDS }
  validates :source_ref, presence: true, length: { maximum: 255 }
  validates :source_note, length: { maximum: 500 }
  validates :recorded_by_session_slug, :recorded_at, presence: true
  validate :person_subject_exists, on: :create
  validate :value_or_pointer, :refuse_identity_data, on: :create

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
    string = text.to_s
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

  def identity_key? = IDENTITY_KEY.match?(key.to_s.downcase.tr("_-", "  "))
  def pointer? = value.blank?
  def sensitive? = sensitivity == "sensitive"
  def superseded? = superseded_by_slug.present?
  def retired? = retired_at.present?
  def current? = !superseded? && !retired?

  # Writes this fact's successor (same subject, key and, unless given,
  # sensitivity) and links this one to it. The predecessor keeps its own value
  # and source.
  def supersede!(recorded_by_session_slug:, **attrs)
    transaction do
      lock!
      refuse_settled!
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

  def person_subject_exists
    return unless subject_type == "person" && subject_slug.present?

    errors.add(:subject_slug, "names no person") unless Person.exists?(slug: subject_slug)
  end

  def value_or_pointer
    if identity_key?
      errors.add(:value, format(POINTER_MESSAGE, "the key names it")) unless pointer?
    elsif pointer?
      errors.add(:value, "can't be blank")
    end
  end

  def refuse_identity_data
    { value: value, source_note: source_note }.each do |attribute, text|
      kind = self.class.identity_kind(text)
      errors.add(attribute, format(POINTER_MESSAGE, kind)) if kind && errors[attribute].empty?
    end
  end
end
