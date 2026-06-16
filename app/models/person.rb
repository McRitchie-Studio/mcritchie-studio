class Person < ApplicationRecord
  include Sluggable

  has_one :athlete_profile, class_name: "Athlete", foreign_key: :person_slug, primary_key: :slug
  has_many :builders, dependent: :restrict_with_exception
  has_many :contracts, foreign_key: :person_slug, primary_key: :slug
  has_many :teams, through: :contracts
  has_many :roster_spots, foreign_key: :person_slug, primary_key: :slug
  has_many :coaches, foreign_key: :person_slug, primary_key: :slug

  validates :first_name, :last_name, presence: true

  # Multi-strategy name lookup: exact slug → normalized slug → alias match
  def self.find_by_name(first_name, last_name)
    full = "#{first_name} #{last_name}".strip
    slug = full.parameterize

    # 1. Exact slug match
    found = find_by(slug: slug)
    return found if found

    # 2. Normalized slug — strip periods, apostrophes, quotes before parameterize
    normalized = full.gsub(/[.'""]/, "").parameterize
    if normalized != slug
      found = find_by(slug: normalized)
      return found if found
    end

    # 3. Alias match — check if any person has this name in their aliases array
    where("aliases @> ?", [full].to_json).first
  end

  # Find by smart name matching, or create. Auto-appends name variant as alias.
  def self.find_or_create_by_name!(first_name, last_name, **attrs)
    person = find_by_name(first_name, last_name)

    if person
      # Auto-add incoming name as alias if it differs from stored full_name
      incoming = "#{first_name} #{last_name}".strip
      if incoming != person.full_name && !person.aliases.include?(incoming)
        person.aliases << incoming
        person.save!
      end
      # Apply boolean flags if passed and not already set
      flags = attrs.slice(:athlete, :coach).select { |k, v| v && !person.send(:"#{k}?") }
      person.update!(flags) if flags.any?
      person
    else
      create!(first_name: first_name, last_name: last_name, **attrs)
    end
  end

  def name_slug
    "#{first_name} #{last_name}".parameterize
  end

  def full_name
    "#{first_name} #{last_name}"
  end
end
