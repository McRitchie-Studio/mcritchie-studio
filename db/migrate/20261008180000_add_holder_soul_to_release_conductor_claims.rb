# The soul a release conductor claim is held under (the admin login the holder's
# session presented at acquire), so the Next Release card and `bin/release status`
# can name who assembles and who ships. Blank when the holder presented no login.
class AddHolderSoulToReleaseConductorClaims < ActiveRecord::Migration[8.1]
  def change
    add_column :release_conductor_claims, :holder_soul, :string
  end
end
