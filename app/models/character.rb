# ONE OF OUR FICTIONAL CAST: a mascot (Turf Monster) or a puppet.
#
# Person stays the table of REAL humans; a Character is a figure we own, so no
# likeness, face-score or identity machinery ever runs for it. What the two
# share is the LOOK: an Appearance belongs to exactly one of them (the
# `appearances_exactly_one_owner` CHECK), and a Character's default look
# resolves and releases by the same rule as a Person's (HoldsDefaultAppearance).
#
# Epic email-image-builder, addendum "Characters", piece A. Piece B gives Turf
# Monster his canonical sheet; piece C puts the character card on the brand kit.
class Character < ApplicationRecord
  include HoldsDefaultAppearance

  KINDS = %w[mascot puppet].freeze

  has_many :appearances, foreign_key: :character_slug, primary_key: :slug, inverse_of: :character,
                         dependent: :destroy
  # Every image the character appears in, alone or beside others.
  has_many :artifact_subjects, foreign_key: :character_slug, primary_key: :slug, inverse_of: :character,
                               dependent: :destroy
  has_many :artifacts, through: :artifact_subjects
  # The look every read falls back to when nothing names one (see Person).
  belongs_to :default_appearance, class_name: "Appearance", foreign_key: :default_appearance_slug,
                                  primary_key: :slug, optional: true

  validates :slug, presence: true, uniqueness: true,
                   format: { with: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, message: "must be lowercase words joined by hyphens" }
  validates :name, presence: true, length: { maximum: 80 }
  validates :kind, inclusion: { in: KINDS }
  validate :brand_is_a_kit

  before_validation :generate_slug, on: :create
  before_validation { self.brand = brand.presence }

  scope :live, -> { where(retired_at: nil) }
  scope :ordered, -> { order(:name, :id) }

  def to_param = slug
  def retired? = retired_at.present?

  # The name a prompt or a page uses. Persons answer `full_name`; Appearance#owner_name
  # reads either.
  def display_name = name

  # The email brand kit this character fronts, or nil.
  def brand_kit = brand.present? ? EmailImages::BrandKit.find(brand) : nil

  # The live character that fronts a brand kit, or nil (the kit page's link).
  def self.featured_for(kit_key)
    return nil if kit_key.blank?

    live.where(brand: kit_key.to_s).order(:created_at, :id).first
  end

  private

  def generate_slug
    self.slug = name.to_s.parameterize if slug.blank?
  end

  def brand_is_a_kit
    return if brand.blank? || EmailImages::BrandKit.find(brand)

    errors.add(:brand, "is not a kit in config/email_brand_kits.yml")
  end
end
