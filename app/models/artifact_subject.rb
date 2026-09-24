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

  after_destroy :retire_artifact_if_cast_gone

  # Falls back to the person's default, which is the point of having one.
  def effective_appearance
    appearance || person&.default_appearance
  end

  def display_name
    person&.full_name.presence || person_slug.to_s.titleize
  end

  private

  # AN ARTIFACT WITH NO SUBJECTS DEPICTS NOBODY, and `live` would still hand it
  # to the reuse lookup with an empty cast label and an empty reuse key.
  #
  # It is reachable without anyone deleting an artifact: `Person has_many
  # :artifact_subjects, dependent: :destroy`, so destroying a person takes their
  # cast rows with them and a solo character sheet outlives the only person in
  # it. RETIRE rather than destroy — the image really was generated, and the row
  # is the only record that it exists.
  def retire_artifact_if_cast_gone
    # The artifact itself going away takes its subjects with it; there is then
    # nothing left to retire, and the last subject would otherwise try to update
    # a row already on its way out.
    return if destroyed_by_association&.active_record == Artifact
    return if ArtifactSubject.where(artifact_slug: artifact_slug).exists?

    art = Artifact.find_by(slug: artifact_slug)
    art.retire! if art && !art.retired?
  end
end
