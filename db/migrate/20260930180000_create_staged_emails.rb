# A broadcast email rendered for one recipient and held, not sent (task
# staged-email-queue): the exact subject and body that will go out, the merge
# fields that made them, and where the row stands (staged → approved → sent, or
# cancelled / skipped). Its own table rather than a state on
# broadcast_deliveries, so a held email never counts as delivered.
class CreateStagedEmails < ActiveRecord::Migration[8.1]
  def change
    create_table :staged_emails do |t|
      t.references :broadcast, null: false, foreign_key: true
      t.references :contact, null: false, foreign_key: true
      t.references :broadcast_delivery, foreign_key: { on_delete: :nullify }
      t.string :status, null: false, default: "staged"
      t.string :skip_reason
      t.string :email
      t.string :delivery_token
      t.jsonb :merge_fields, null: false, default: {}
      t.string :rendered_subject
      t.text :rendered_html
      t.text :rendered_text
      t.datetime :staged_at
      t.datetime :approved_at
      t.datetime :queued_at
      t.datetime :sent_at
      t.datetime :cancelled_at
      t.datetime :scheduled_for
      t.timestamps
    end
    add_index :staged_emails, %i[broadcast_id contact_id], unique: true
    add_index :staged_emails, %i[broadcast_id status]
    add_index :staged_emails, :delivery_token, unique: true, where: "delivery_token IS NOT NULL"
  end
end
