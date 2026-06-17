require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "display_name returns name when present" do
    user = users(:alex)
    assert_equal "Alex McRitchie", user.display_name
  end

  test "display_name returns capitalized email prefix when name is blank" do
    user = User.create!(email: "newuser@example.com", password: "password")
    assert_equal "Newuser", user.display_name
  end

  test "admin? returns true for admin role" do
    assert users(:alex).admin?
  end

  test "admin? returns false for viewer role" do
    assert_not users(:viewer).admin?
  end

  test "slug is set on save" do
    user = users(:alex)
    user.save!
    assert user.slug.present?
  end

  test "to_param returns slug" do
    user = users(:alex)
    user.save!
    assert_equal user.slug, user.to_param
  end

  test "avatar_initials returns first letter of name" do
    user = users(:alex)
    assert_equal "A", user.avatar_initials
  end

  test "avatar_initials uses email when no name" do
    user = User.create!(email: "test@example.com", password: "password")
    assert_equal "T", user.avatar_initials
  end

  test "avatar_color is deterministic" do
    user = users(:alex)
    color1 = user.avatar_color
    color2 = user.avatar_color
    assert_equal color1, color2
    assert_match(/^#[0-9A-Fa-f]{6}$/, color1)
  end

  # --- from_omniauth tests ---

  def google_auth(email: "newgoogle@example.com", name: "Google User", uid: "123456")
    OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: uid,
      info: { email: email, name: name }
    )
  end

  test "from_omniauth creates new user when no match" do
    auth = google_auth

    assert_difference "User.count", 1 do
      user = User.from_omniauth(auth, email_verified: true)
      assert_equal "newgoogle@example.com", user.email
      assert_equal "Google User", user.name
      assert_equal "google_oauth2", user.provider
      assert_equal "123456", user.uid
      assert user.email_verified_at.present?
    end
  end

  test "from_omniauth links existing user by email when Google-verified" do
    alex = users(:alex)
    auth = google_auth(email: alex.email, uid: "99999")

    assert_no_difference "User.count" do
      user = User.from_omniauth(auth, email_verified: true)
      assert_equal alex.id, user.id
      assert_equal "google_oauth2", user.provider
      assert_equal "99999", user.uid
    end
  end

  test "from_omniauth refuses to link an existing email when not Google-verified (OPSEC-005)" do
    alex = users(:alex)
    auth = google_auth(email: alex.email, uid: "88888")

    assert_no_difference "User.count" do
      assert_equal :email_not_verified, User.from_omniauth(auth, email_verified: false)
    end
    assert_nil alex.reload.provider
  end

  test "from_omniauth returns existing OAuth user" do
    auth = google_auth(email: "oauth@example.com", uid: "55555")
    original = User.from_omniauth(auth, email_verified: true)

    assert_no_difference "User.count" do
      returning = User.from_omniauth(auth, email_verified: true)
      assert_equal original.id, returning.id
    end
  end

  # --- wallet + auth-method tests ---

  test "from_solana_wallet finds by solana_address" do
    user = User.create!(solana_address: "Wa11etAddressBase58Example1111111111111111")
    assert_equal user.id, User.from_solana_wallet(user.solana_address).id
    assert_nil User.from_solana_wallet("nope")
  end

  test "parked identity can be found by email or wallet" do
    wallet = User.parked_identity_for(email: "team@mcritchie.studio").fetch(:wallet)

    assert_equal "team@mcritchie.studio", User.parked_identity_for(wallet: wallet).fetch(:email)
  end

  test "parked email signup gets canonical admin identity" do
    user = User.create!(email: "team@mcritchie.studio")

    assert user.admin?
    assert_equal "McRitchie Studio Team", user.name
    assert_equal "8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd", user.solana_address
  end

  test "parked wallet signup gets canonical email identity" do
    wallet = User.parked_identity_for(email: "team@mcritchie.studio").fetch(:wallet)
    user = User.create!(solana_address: wallet)

    assert_equal "team@mcritchie.studio", user.email
    assert user.admin?
  end

  test "from_solana_wallet links parked wallet to existing email user" do
    user = User.create!(email: "team@mcritchie.studio")
    user.update_column(:solana_address, nil)

    found = User.from_solana_wallet(User.parked_identity_for(email: user.email).fetch(:wallet))

    assert_equal user.id, found.id
    assert_equal "admin", found.role
    assert_equal User.parked_identity_for(email: user.email).fetch(:wallet), found.solana_address
  end

  test "wallet-only user is valid without email and gets a unique slug" do
    addr = "Wa11etAddrTwo2222222222222222222222222222"
    user = User.create!(solana_address: addr)
    assert user.persisted?
    assert user.solana_connected?
    assert user.phantom_wallet?
    # display falls back to the truncated wallet address
    assert_equal "#{addr[0, 4]}…#{addr[-4, 4]}", user.display_name
    assert user.slug.present?
  end

  test "user with no auth method is invalid" do
    user = User.new(name: "Nobody")
    assert_not user.valid?
    assert user.errors[:base].any?
  end

  test "session_token is set on create" do
    user = User.create!(email: "tokened@example.com")
    assert user.session_token.present?
  end
end
