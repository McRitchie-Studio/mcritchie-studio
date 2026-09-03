class CreateDeskCaptureItems < ActiveRecord::Migration[8.1]
  def change
    create_table :desk_capture_items do |t|
      # SES drops raw MIME at this key in the private desk bucket — the poller's
      # idempotency anchor: one row per object, ever.
      t.string :s3_key, null: false
      # Message-ID header — second dedup line (a re-forwarded mail gets a new
      # S3 object but keeps its Message-ID; we keep both rows but can see it).
      t.string :message_id
      t.string :from_addr
      t.string :subject
      t.datetime :received_at
      # received  — parsed, awaiting the capture sweep
      # quarantined — sender not allowlisted; raw kept, attachments NOT extracted
      # filed     — the sweep filed its contents into an entity's knowledge layer
      # ignored   — the sweep judged it noise
      t.string :status, null: false, default: "received"
      # Entity routing hint parsed from a [tag] in the subject or a plus-address
      # (team+welding@...). The sweep confirms; a hint is never trusted blindly.
      t.string :entity_hint
      t.text :body_text
      # [{"filename":, "s3_key":, "content_type":, "byte_size":}, ...]
      t.jsonb :attachments, null: false, default: []
      # What the sweep did with it, in one line.
      t.text :filed_note

      t.timestamps
    end

    add_index :desk_capture_items, :s3_key, unique: true
    add_index :desk_capture_items, [ :status, :received_at ]
  end
end
