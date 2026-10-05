# A music artist: one performer (kind "person") or a group. Groups are credited
# directly (Migos is one artist); memberships link members to groups.
class Artist < ApplicationRecord
  KINDS = %w[person group].freeze

  belongs_to :person, foreign_key: :person_slug, primary_key: :slug, optional: true
  has_many :aliases, class_name: "ArtistAlias", foreign_key: :artist_slug, primary_key: :slug,
           inverse_of: :artist, dependent: :destroy
  has_many :group_memberships, class_name: "ArtistMembership", foreign_key: :member_artist_slug,
           primary_key: :slug, inverse_of: :member, dependent: :destroy
  has_many :member_memberships, class_name: "ArtistMembership", foreign_key: :group_artist_slug,
           primary_key: :slug, inverse_of: :group, dependent: :destroy
  has_many :groups, through: :group_memberships, source: :group
  has_many :members, through: :member_memberships, source: :member

  validates :slug, :name, :sort_name, presence: true
  validates :slug, uniqueness: true
  validates :kind, inclusion: { in: KINDS }
  validates :wikidata_id, uniqueness: true, allow_nil: true
  validate :person_link_only_for_individuals

  before_validation :default_sort_name
  # A person linked to an artist is a musician (Person::VOCATIONS).
  after_save -> { person&.add_vocation!("musician") }, if: :saved_change_to_person_slug?

  scope :people, -> { where(kind: "person") }
  scope :groups, -> { where(kind: "group") }

  def to_param = slug

  def group? = kind == "group"

  # "The Roots" sorts as "Roots, The". Anything else sorts as named.
  def self.sort_name_for(name)
    name.to_s.match(/\AThe\s+(.+)\z/i) { |m| "#{m[1]}, The" } || name.to_s
  end

  # A free slug for a new artist: the name's, then -2, -3 and so on.
  def self.available_slug(name)
    base = name.to_s.parameterize.presence || "artist"
    taken = where("slug = :b OR slug LIKE :p", b: base, p: "#{sanitize_sql_like(base)}-%").pluck(:slug).to_set
    return base unless taken.include?(base)

    (2..).each { |n| return "#{base}-#{n}" unless taken.include?("#{base}-#{n}") }
  end

  private

  def default_sort_name
    self.sort_name = self.class.sort_name_for(name) if sort_name.blank?
  end

  def person_link_only_for_individuals
    errors.add(:person_slug, "is only for individual artists") if person_slug.present? && group?
  end
end
