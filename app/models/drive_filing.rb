# One write of GoogleConnect::DriveFiler to a connected account's Drive: the
# audit log of every folder the hub makes and every file it files there
# (/tasks/drive-filing). A dry run is logged too (applied false), so the log
# shows what was asked before anything changed. A `mkdir` row is one folder
# path made or found; an `upload` row is one file, with its name, size, md5,
# where it came from (`source`: "local" or "gmail") and the Drive id Google
# answered. `duplicate` is true when a file with the same md5 already sat in
# that folder, so nothing was uploaded and drive_file_id names the one there.
# The row never holds the file's bytes. `mailbox` is a string, not a key, so
# the record outlives a disconnect.
class DriveFiling < ApplicationRecord
  ACTIONS = %w[mkdir upload].freeze
  SOURCES = %w[local gmail].freeze

  validates :mailbox, :requested_by, :folder_path, presence: true
  validates :action, inclusion: { in: ACTIONS }
  validates :source, inclusion: { in: SOURCES }, allow_nil: true

  scope :newest_first, -> { order(created_at: :desc, id: :desc) }
  scope :for_mailbox, ->(mailbox) { where(mailbox: mailbox.to_s.downcase) }
end
