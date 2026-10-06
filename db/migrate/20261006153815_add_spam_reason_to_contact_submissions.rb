class AddSpamReasonToContactSubmissions < ActiveRecord::Migration[8.1]
  def change
    add_column :contact_submissions, :spam_reason, :string
  end
end
