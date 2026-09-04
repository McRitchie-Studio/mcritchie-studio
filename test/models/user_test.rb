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
    # DERIVED, not spelled out. This test is about the callback ADOPTING the
    # canonical identity; pinning the literal made the 2026-09-04 rename
    # ("McRitchie Studio Team" -> "Team McRitchie") fail here as though adoption
    # had broken. The name itself is pinned once, in ParkedIdentitiesTest.
    assert_equal User.parked_identity_for(email: "team@mcritchie.studio").fetch(:name), user.name
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
  # --- the parked identities ------------------------------------------------

  # WHY THIS IS ASSERTED. Every parked identity was an admin, so an ordinary
  # member could not be signed in as locally at all — admin-only pages, member
  # copy and anything branching on a role each had exactly one answer available.
  test "a non-admin identity is parked alongside the admins" do
    members = User::PARKED_IDENTITIES.reject { |identity| identity[:role] == "admin" }

    refute_empty members, "with every identity an admin, nothing can be tested as a member"
  end

  # Mack specifically, because he is already the non-admin in turf-monster —
  # one person meaning the same thing in both apps rather than each app growing
  # its own stand-in.
  test "mack is the parked member, and reads as one" do
    mack = User::PARKED_IDENTITIES.find { |identity| identity[:email] == "mack@mcritchie.studio" }

    refute_nil mack, "the shared non-admin identity should stay parked"
    assert_equal "viewer", mack[:role]
    refute User.new(email: mack[:email], name: mack[:name], role: mack[:role]).admin?
  end

  # NOT a seed test — the seed is never loaded here. The role is re-applied by
  # `before_validation :assign_parked_identity`, so a parked account cannot be
  # saved into a role the roster contradicts, and that is what this asserts.
  #
  # An earlier version of this called itself "the seed can demote an admin" and
  # was tautological: the callback means the row is created a viewer, so setting
  # role: "admin" was a no-op and the assertion could not fail.
  test "a parked identity cannot be saved into a role the roster contradicts" do
    mack = User.create!(email: "mack@mcritchie.studio", name: "Mack McRitchie", password: "password")

    mack.update!(role: "admin")

    refute mack.reload.admin?,
      "the roster must win over a hand-set role, or a demotion never reaches existing rows"
  end

end
