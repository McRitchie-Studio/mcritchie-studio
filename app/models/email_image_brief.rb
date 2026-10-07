# frozen_string_literal: true

# A REQUEST FOR ONE EMAIL'S HEADER IMAGE (epic email-image-builder, piece 1).
#
# The brief says which email (app, email_key, variant), which brand kit, and
# what the header says. Its candidates are Artifact rows of kind
# `email_header` carrying this brief's slug; the approved one is named by
# `approved_artifact_slug`. The build columns hold the claim/take/finish state
# EmailImages::Build runs on, the same shape Appearances::SheetBuild keeps on a
# look.
class EmailImageBrief < ApplicationRecord
  # `composited` is piece 3. The column is a plain string so adding it is a
  # one-word change here, not a migration.
  TEXT_MODES = %w[baked none].freeze
  IMAGE_FORMATS = %w[jpg png].freeze
  SLUG_PART = /\A[a-z0-9][a-z0-9_-]*\z/

  BUILDING = "building"
  DONE = "done"
  FAILED = "failed"

  has_many :candidates, -> { where(kind: "email_header").order(created_at: :desc, id: :desc) },
           class_name: "Artifact", foreign_key: :brief_slug, primary_key: :slug, inverse_of: false

  validates :slug, presence: true, uniqueness: true
  validates :app, :email_key, :variant, presence: true, format: { with: SLUG_PART }
  validates :email_key, uniqueness: { scope: %i[app variant] }
  validates :headline, presence: true, length: { maximum: 120 }
  validates :text_mode, inclusion: { in: TEXT_MODES }
  validates :image_format, inclusion: { in: IMAGE_FORMATS }
  validates :max_rounds, numericality: { only_integer: true, greater_than: 0 }
  validate :brand_kit_exists
  validate :preset_exists

  before_validation :fill_defaults, on: :create

  scope :ordered, -> { order(:app, :email_key, :variant) }

  def to_param = slug

  def kit = EmailImages::BrandKit.find(brand_kit)
  def preset_config = EmailImages::BrandKit.preset(preset)

  # THE ALT TEXT IS THE HEADLINE unless an admin wrote a better one: an email
  # header never ships without alt text.
  def effective_alt_text = alt_text.presence || headline

  def building? = build_state == BUILDING && !build_stale?
  def build_stale? = build_state == BUILDING && build_started_at.present? &&
                     build_started_at < EmailImages::Build::STALE_AFTER.ago

  def rounds_left = [max_rounds - rounds_used, 0].max
  def rounds_exhausted? = rounds_left.zero?

  def approved_artifact
    return nil if approved_artifact_slug.blank?

    candidates.find { |a| a.slug == approved_artifact_slug } ||
      Artifact.find_by(slug: approved_artifact_slug)
  end

  def live_candidates = candidates.select { |a| a.retired_at.nil? }

  # APPROVE ONE CANDIDATE. Only one header ships per email, so approving a
  # second candidate retires the first. One transaction: the brief never names
  # an artifact that is not approved, and two approved headers never coexist.
  def approve!(artifact, by:)
    raise ArgumentError, "#{artifact.slug} is not a candidate of #{slug}" unless artifact.brief_slug == slug

    transaction do
      previous = approved_artifact
      previous.retire! if previous && previous.slug != artifact.slug && !previous.retired?
      artifact.update!(approved_at: Time.current, approved_by: by, retired_at: nil)
      update!(approved_artifact_slug: artifact.slug)
    end
  end

  # RETIRE ONE CANDIDATE. Retiring the approved one leaves the brief with no
  # approved header, which the page then says.
  def retire!(artifact)
    raise ArgumentError, "#{artifact.slug} is not a candidate of #{slug}" unless artifact.brief_slug == slug

    transaction do
      artifact.retire!
      update!(approved_artifact_slug: nil) if approved_artifact_slug == artifact.slug
    end
  end

  # RUNNING SPEND, in the vendor's own unit. Dollars only where a row declares
  # a rate; a nil cost is unpriced, never free.
  def billable_units_total = candidates.sum { |a| a.billable_units.to_i }
  def cost_usd_total
    priced = candidates.map(&:cost_usd).compact
    priced.empty? ? nil : priced.sum
  end

  # The file name piece 2 commits into the app, matching how Turf names its
  # banners (app/assets/images/emails/<name>-banner.jpg).
  def asset_filename = "#{email_key.tr('_', '-')}-#{variant.tr('_', '-')}-banner.#{image_format}"

  # The catalog key the app will register, e.g. drop_signup_confirmation_new_player.
  def catalog_key = variant == "default" ? email_key : "#{email_key}_#{variant}"

  # The R2 folder every candidate of this brief is stored under
  # (Appearances::StoreGeneratedImage, prefix email_images).
  def storage_subject = "#{app}/#{email_key}/#{variant}"

  private

  def fill_defaults
    self.variant = variant.presence || "default"
    self.slug ||= [app, email_key, variant].compact_blank.join("-").tr("_", "-").presence
    self.max_rounds ||= EmailImages::BrandKit.max_rounds
    self.brand_kit = brand_kit.presence || app
  end

  def brand_kit_exists
    errors.add(:brand_kit, "is not a kit in config/email_brand_kits.yml") if kit.nil?
  end

  def preset_exists
    errors.add(:preset, "is not a preset in config/email_brand_kits.yml") if preset_config.nil?
  end
end
