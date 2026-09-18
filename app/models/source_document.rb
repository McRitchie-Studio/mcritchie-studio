# One document in an external knowledge layer — its METADATA, never its bytes.
#
# The two jobs this row does:
#
#   1. Say the document exists and where: external_id, title, type, link, owner.
#   2. Say whether the app's understanding of it is current. The layer's own
#      change signal lands in remote_version on every walk; indexed_version is
#      what the index last acted on. When they differ, it needs indexing.
#
# Triage fields (entity, access, tags) are written ONCE, at create, from the
# source's defaults. A walk refreshes the remote_* columns and never touches
# them, so a human re-classification survives every re-walk — the same rule
# Slack::ChannelIngest follows for KnowledgeDocs.
class SourceDocument < ApplicationRecord
  STATUSES = %w[active missing].freeze

  # Columns a walk may write. Everything else belongs to triage or the indexer.
  REMOTE_ATTRIBUTES = %i[title mime_type web_url owner_email byte_size remote_version
                         remote_modified_at checksum parents metadata].freeze

  belongs_to :knowledge_source

  validates :external_id, presence: true, uniqueness: { scope: :knowledge_source_id }
  validates :status, inclusion: { in: STATUSES }

  scope :active,  -> { where(status: "active") }
  scope :missing, -> { where(status: "missing") }

  # THE FRESHNESS RULE. Never indexed, or the layer's version has moved.
  #
  # Compared by VERSION, not by timestamp: remote_modified_at can lag, tie at
  # one-second resolution, or move without a content change, while Drive's
  # version is a strictly increasing counter. A document with no version at
  # all (a layer that offers none) falls back to the timestamp.
  def needs_indexing?
    return true if last_indexed_at.nil?
    return indexed_version != remote_version if remote_version.present?

    remote_modified_at.present? && remote_modified_at > last_indexed_at
  end

  # The seam the indexer calls once it has acted on this version. Records WHICH
  # version it acted on, so a change that lands mid-index is still seen as new.
  def mark_indexed!(version: remote_version, at: Time.current)
    update!(indexed_version: version, last_indexed_at: at)
  end
end
