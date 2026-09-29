# Email verification results on a contact (task verify-contacts-with-zerobounce):
# ZeroBounce's status and sub-status, and when the check ran. A contact with
# verified_at is never resubmitted, so a verification credit is spent once.
class AddVerificationToContacts < ActiveRecord::Migration[8.1]
  def change
    add_column :contacts, :verification_status, :string
    add_column :contacts, :verification_sub_status, :string
    add_column :contacts, :verified_at, :datetime
    add_index :contacts, :verification_status
  end
end
