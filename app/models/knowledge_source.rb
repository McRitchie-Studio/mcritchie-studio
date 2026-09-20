# One knowledge LAYER instance the app indexes — a shared Drive folder today,
# an Egnyte space or a transcript collection tomorrow.
#
# The layer is the source of truth. This row records only where it is and how to
# walk it; its documents are indexed as metadata (SourceDocument) and never
# copied. See the migration for the operator's no-duplication rule.
class KnowledgeSource < ApplicationRecord
  KINDS = %w[google_drive egnyte transcripts].freeze

  # A folder is always walked AS a named subject. Optional on the record so
  # existing rows survive the migration; the walker REFUSES a source without
  # one rather than falling back to a global identity.
  belongs_to :workspace_account, optional: true
  has_many :source_documents, dependent: :destroy

  validates :kind, inclusion: { in: KINDS }
  validates :name, presence: true
  validates :external_root_id, presence: true, uniqueness: { scope: :kind }
  validate :access_levels_are_known

  scope :enabled, -> { where(enabled: true) }

  # Documents whose remote state has moved past what the index last acted on.
  def stale_documents
    source_documents.active.select(&:needs_indexing?)
  end

  private

  # Same three levels as the knowledge layer, read from the engine so the two
  # can never drift apart.
  def access_levels_are_known
    return if access.blank?
    return errors.add(:access, "must map an agent to a level") unless access.is_a?(Hash)

    levels = Studio::KnowledgeDoc::ACCESS_LEVELS
    access.each do |agent, level|
      errors.add(:access, "#{agent} has unknown level #{level.inspect}") unless levels.include?(level.to_s)
    end
  end
end
