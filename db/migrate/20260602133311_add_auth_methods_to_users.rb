class AddAuthMethodsToUsers < ActiveRecord::Migration[7.2]
  def change
    # Passwordless + wallet sign-in support. session_token binds the cookie to a
    # rotatable per-user secret (OPSEC-045); solana_address is the wallet identity
    # (Phantom); email_verified_at is stamped when a magic link is consumed.
    add_column :users, :session_token, :string
    add_column :users, :solana_address, :string
    add_column :users, :email_verified_at, :datetime

    add_index :users, :solana_address, unique: true

    # Wallet-only users have no email — drop the NOT NULL. Uniqueness (existing
    # index) still holds, and the model allows nil.
    change_column_null :users, :email, true
  end
end
