# One Drive file a person chose in the Google Picker for their GoogleConnection
# (/tasks/drive-files-you-pick). Under drive.file these are the only files the
# hub can open for that connection, and the only ones its agents read
# (GoogleConnect::DriveReader#picked). Recorded only after the hub has read the
# file's metadata with the connection's own token (Integrations::DrivePicksController),
# so a row names a file Google really handed over.
#
# Files only: Google documents no grant of a folder's contents under drive.file,
# and the one first-hand report says there is none (the task note on
# drive-files-you-pick), so the Picker offers no folder selection and a folder
# id is refused here.
class GoogleDrivePick < ApplicationRecord
  FOLDER_MIME = "application/vnd.google-apps.folder".freeze

  # touch: a pick or unpick changes the connection's updated_at, which
  # GoogleConnect::OwnerContext folds into its cache key.
  belongs_to :google_connection, inverse_of: :drive_picks, touch: true

  validates :file_id, presence: true, uniqueness: { scope: :google_connection_id }, format: { with: /\A[\w-]+\z/ }
  validates :name, :picked_at, presence: true
  validate :not_a_folder

  scope :newest_first, -> { order(picked_at: :desc, id: :desc) }

  private

  def not_a_folder
    errors.add(:base, "A folder cannot be picked: share it with your agent's address instead") if mime_type == FOLDER_MIME
  end
end
