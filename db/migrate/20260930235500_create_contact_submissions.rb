# The public /contact form's record. Each row is durable proof of what a visitor
# was shown and what they agreed to: the three SMS consent answers, the exact
# disclosure text on the page at that moment, and when and where it came from.
# Rows are never edited after insert (see ContactSubmission).
class CreateContactSubmissions < ActiveRecord::Migration[8.1]
  def change
    create_table :contact_submissions do |t|
      t.string :name, null: false
      t.string :email, null: false
      t.string :phone
      t.text :message, null: false
      t.boolean :sms_care_consent, null: false, default: false
      t.boolean :sms_marketing_consent, null: false, default: false
      t.boolean :sms_declined, null: false, default: false
      t.string :disclosure_version, null: false
      t.text :disclosure_text, null: false
      t.string :ip_address
      t.text :user_agent
      t.timestamps
    end

    add_index :contact_submissions, :created_at
    add_index :contact_submissions, "lower((email)::text)", name: "index_contact_submissions_on_lower_email"
  end
end
