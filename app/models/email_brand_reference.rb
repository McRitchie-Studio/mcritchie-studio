# frozen_string_literal: true

# A REFERENCE IMAGE AN ADMIN ADDED TO AN EMAIL BRAND KIT (task
# email-brand-asset-page): a new mascot pose, a logo lockup, a style anchor.
#
# The kit's base references stay in config/email_brand_kits.yml; these rows are
# the ones added on /email_images/brand_kits/<kit>. EmailImages::BrandKit merges
# the active rows with the YAML references, and that merged list is what the
# page shows, what `bin/email-image assets` prints, and what the generator picks
# from (EmailImages::BrandKit#generator_references).
#
# OUR OWN MARKS ONLY. No photo of a real person or athlete and no team logo:
# the upload form says so, and the kit's `negative` rules ride every prompt.
#
# Archiving keeps the row (and the stored image) so an old round's provenance
# still resolves; an archived reference is never offered to the generator.
class EmailBrandReference < ApplicationRecord
  ROLES = %w[mascot logo style product other].freeze
  MAX_BYTES = 5 * 1024 * 1024
  # The content types an upload may be, read from its bytes, never its name.
  CONTENT_TYPES = { "png" => "image/png", "jpg" => "image/jpeg", "webp" => "image/webp" }.freeze
  STORAGE_PREFIX = "email_brand"

  validates :slug, presence: true, uniqueness: true
  validates :role, inclusion: { in: ROLES }
  validates :label, presence: true, length: { maximum: 80 }
  validates :note, length: { maximum: 500 }
  validates :image_url, presence: true
  validates :content_type, inclusion: { in: CONTENT_TYPES.values }
  validates :byte_size, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: MAX_BYTES }
  validate :brand_kit_exists

  before_validation { self.slug ||= "ref-#{SecureRandom.hex(6)}" }

  scope :active, -> { where(archived_at: nil) }
  scope :archived, -> { where.not(archived_at: nil) }
  # Newest first, id as the tie-break, so two uploads in the same second still
  # order the same way every time (the generator's selection depends on it).
  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  def to_param = slug
  def archived? = archived_at.present?
  def archive! = update!(archived_at: Time.current)

  # The R2 folder an upload is stored under: email_brand/<kit>/refs/<time>-<hex>.<ext>.
  def self.storage_subject(kit_key) = "#{kit_key}/refs"

  # The image type the BYTES are (PNG, JPEG or WebP), or nil for anything else,
  # whatever the file is called.
  def self.content_type_of(bytes)
    ext = EmailImages::Download.extension_for(bytes.to_s, default: nil)
    CONTENT_TYPES[ext]
  end

  private

  def brand_kit_exists
    errors.add(:brand_kit, "is not a kit in config/email_brand_kits.yml") if EmailImages::BrandKit.find(brand_kit).nil?
  end
end
