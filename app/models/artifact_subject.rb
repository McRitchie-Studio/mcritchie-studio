# One person IN one artifact, wearing one look.
#
# THE JOIN THAT REMOVES THE CEILING. The shape this replaced carried
# `secondary_player_slug` and capped at two people, which a three-person cast
# breaks immediately. A trio is three rows here.
#
# The APPEARANCE lives on the subject rather than on the artifact, which is the
# whole reason a mixed cast works: Burrow in a Bengals jersey, Bush at a podium
# and Carrey in character are three different looks inside one frame.
class ArtifactSubject < ApplicationRecord
  belongs_to :artifact, foreign_key: :artifact_slug, primary_key: :slug, inverse_of: :subjects
  belongs_to :person, foreign_key: :person_slug, primary_key: :slug, optional: true
  belongs_to :appearance, foreign_key: :appearance_slug, primary_key: :slug, optional: true

  validates :person_slug, presence: true

  scope :ordered, -> { order(:ordinal, :id) }

  # Falls back to the person's default, which is the point of having one.
  def effective_appearance
    appearance || person&.default_appearance
  end

  def display_name
    person&.full_name.presence || person_slug.to_s.titleize
  end
end
