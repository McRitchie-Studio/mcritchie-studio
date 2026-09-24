class Person < ApplicationRecord
  include Sluggable

  has_one :athlete_profile, class_name: "Athlete", foreign_key: :person_slug, primary_key: :slug
  has_many :appearances, foreign_key: :person_slug, primary_key: :slug, inverse_of: :person, dependent: :destroy
  has_many :artifact_subjects, class_name: "ArtifactSubject", foreign_key: :person_slug, primary_key: :slug, dependent: :destroy
  has_many :artifacts, through: :artifact_subjects
  # The look every read falls back to when nothing names one. Most flows never
  # name an appearance at all and simply get this one.
  #
  # Stamped by whichever write files this person's FIRST look — a model created
  # by hand, or an image attached at a content's inspection gate, which files
  # the look it was uploaded for (Appearance.file_for_colorway!). A later look
  # does not take the slot while the current one still stands; a look that goes
  # away RELEASES it (see #resolve_default_appearance!).
  belongs_to :default_appearance, class_name: "Appearance", foreign_key: :default_appearance_slug,
             primary_key: :slug, optional: true
  has_many :builders, dependent: :restrict_with_exception
  has_many :contracts, foreign_key: :person_slug, primary_key: :slug
  has_many :teams, through: :contracts
  has_many :roster_spots, foreign_key: :person_slug, primary_key: :slug
  has_many :coaches, foreign_key: :person_slug, primary_key: :slug

  validates :first_name, :last_name, presence: true

  # RE-RESOLVE THE DEFAULT POINTER AGAINST REALITY.
  #
  # `default_appearance_slug` is a plain string column with NO foreign key, and
  # for a long time exactly one callback wrote it — an after_CREATE. So every
  # transition that is not a create left it describing a world that had moved:
  # destroy the look it names and the column still names it, so
  # #default_appearance returns nil while the person plainly has looks, and
  # because Appearance#become_default_if_first only ever fired on a BLANK
  # pointer, nothing could refill it. "Has looks, resolves no default" was
  # permanent, and had nothing to grep for.
  #
  # Keeps a pointer that still names a LIVE look, otherwise takes the oldest
  # live look, otherwise blanks the column. Returns the slug it settled on.
  #
  # Writes with update_columns deliberately: this is pointer hygiene run from
  # inside other people's callbacks (a look being destroyed, a merge handing
  # looks to a survivor), and it must not re-enter validation or bump
  # updated_at on a person nobody edited.
  def resolve_default_appearance!
    current = default_appearance_slug
    return current if current.present? && appearances.live.exists?(slug: current)

    settled = appearances.live.order(:created_at, :id).first&.slug
    update_columns(default_appearance_slug: settled) if persisted? && !destroyed?
    self.default_appearance_slug = settled
    settled
  end

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

  # Two active players can share a name — six do in the 2026 league, measured against the feed on 2026-09-21 —
  # so a name-derived slug is not unique on its own. A genuine namesake carries
  # a `disambiguator` (a stable fragment of their league ID); everyone else
  # keeps the clean "first-last" slug, which is almost everyone.
  def name_slug
    base = "#{first_name} #{last_name}".parameterize
    disambiguator.present? ? "#{base}-#{disambiguator}" : base
  end

  def full_name
    "#{first_name} #{last_name}"
  end
end
