# The desk queue gained a second inbound transport (the Gmail mailbox read), and
# the two doors do NOT deserve the same trust. `source` records which one an
# item came through so the sweep — and the allowlist — can tell them apart.
#
# `history_id` is the Gmail read's CURSOR, deliberately stored on the item
# rather than in a cursor of its own: the next pull resumes from the max
# history_id it has durably recorded, so the cursor can never advance past a
# message whose row was not written.
class AddSourceAndHistoryIdToDeskCaptureItems < ActiveRecord::Migration[8.1]
  def change
    add_column :desk_capture_items, :source, :string, null: false, default: "resend"
    add_column :desk_capture_items, :history_id, :bigint

    add_index :desk_capture_items, [ :source, :history_id ]
  end
end
