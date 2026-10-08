# frozen_string_literal: true

# A PIECE OF JEWELRY A PERSON OWNS, as the iced-out character sheet should draw
# it: a Super Bowl ring, a chain, a watch. The source of truth for the iced
# prompt's jewelry clause (Appearances::CharacterSheetPrompt, iced: true), so a
# person with ring records is drawn wearing THOSE rings rather than generic ones.
#
# `description` is the text the prompt uses, so it says what the piece looks
# like, not where it came from (that is `source`). Entered by an admin on the
# person page; nothing seeds real people's jewelry.
class PersonJewelry < ApplicationRecord
  # The order the person page lists them in, and the order the prompt reads them.
  KINDS = %w[super_bowl_ring championship_ring chain watch bracelet grill other].freeze
  # A ring for a title is named by its season, so it needs the year.
  CHAMPIONSHIP_KINDS = %w[super_bowl_ring championship_ring].freeze
  RING_KINDS = CHAMPIONSHIP_KINDS

  IMAGE_URL_REFUSED = "must be an https:// URL on a public host"
  IMAGE_URL_UNCHECKED = "could not be checked right now: its host could not be looked up. " \
                        "Confirm the host name, or try again in a moment"

  belongs_to :person, foreign_key: :person_slug, primary_key: :slug, inverse_of: :jewelries

  validates :slug, presence: true, uniqueness: true
  validates :kind, inclusion: { in: KINDS }
  validates :name, presence: true, length: { maximum: 120 }
  validates :description, presence: true, length: { maximum: 600 }
  validates :year, presence: true, if: :championship?
  validates :year, numericality: { only_integer: true, greater_than: 1900, less_than: 2200 }, allow_nil: true
  # Only when the URL changes (a new piece with a URL is a change). On the next
  # engine this check is a DNS lookup that can take seconds and can fail, and a
  # rename must not be refused because a CDN's name did not look up.
  validate :image_url_is_public_https, if: :will_save_change_to_image_url?

  before_validation :generate_slug, on: :create
  before_validation :normalize

  scope :ordered, -> { in_order_of(:kind, KINDS).order(:year, :id) }
  scope :rings, -> { where(kind: RING_KINDS) }

  def championship? = CHAMPIONSHIP_KINDS.include?(kind)
  def ring? = RING_KINDS.include?(kind)

  def kind_label = kind.to_s.humanize

  # How the prompt names the piece: "his 2019 Super Bowl ring (Super Bowl LIV
  # ring): white gold, ..."
  def prompt_phrase
    title = [year, name].compact.join(" ")
    "#{title}: #{description}"
  end

  private

  # The page renders it and the prompt may hand it on, so the same rule as an
  # attached sheet: https on a public host, or blank. A host that could not be
  # looked up is a different answer from a bad address: nothing is wrong with
  # what was typed that trying again may not fix.
  def image_url_is_public_https
    return if image_url.blank?

    case Appearances::FetchableUrl.https_verdict(image_url)
    when Appearances::FetchableUrl::OK then nil
    when Appearances::FetchableUrl::UNRESOLVED then errors.add(:image_url, IMAGE_URL_UNCHECKED)
    else errors.add(:image_url, IMAGE_URL_REFUSED)
    end
  end

  def normalize
    self.name = name.to_s.squish.presence
    self.description = description.to_s.strip.presence
    self.image_url = image_url.to_s.strip.presence
    self.source = source.to_s.strip.presence
  end

  def generate_slug
    self.slug ||= "jewel-#{SecureRandom.hex(6)}"
  end
end
