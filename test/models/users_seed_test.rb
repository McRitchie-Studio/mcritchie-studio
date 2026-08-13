require "test_helper"

# Exercises db/seeds/01_users.rb directly. It runs on every deploy, so the
# properties that matter are that it lands the parked roster, that it is
# idempotent, and — the reason this file exists — that it can take admin AWAY.
#
# The seed is the durable source of truth for who is an admin. Its
# find_or_create_by! block only runs on CREATE, so a role change on an EXISTING
# row depends entirely on the separate update! that follows. Without that line
# the roster is write-once: mack was created an admin by an earlier seed, and
# demoting him in PARKED_IDENTITIES would change nothing on any environment that
# had already run.
class UsersSeedTest < ActiveSupport::TestCase
  SEED = Rails.root.join("db/seeds/01_users.rb").to_s

  def run_seed
    capture_io { load SEED }
  end

  def parked(email) = User::PARKED_IDENTITIES.find { |identity| identity[:email] == email }

  test "seeds every parked identity and is idempotent" do
    run_seed
    first = User.count

    User::PARKED_IDENTITIES.each do |identity|
      assert User.exists?(email: identity[:email]), "#{identity[:email]} was not seeded"
    end

    run_seed
    assert_equal first, User.count, "re-running the seed must not create duplicates"
  end

  test "the seed lands mack as a member, not an admin" do
    run_seed
    mack = User.find_by(email: "mack@mcritchie.studio")

    refute_nil mack
    refute mack.admin?, "this app needs an account that is not an admin"
    assert_equal parked("mack@mcritchie.studio")[:role], mack.role
  end

  # HOW THE DEMOTION ACTUALLY REACHES EXISTING ROWS — and it is not the seed.
  #
  # mack already exists as an admin in every environment that has run this seed
  # before, so changing PARKED_IDENTITIES has to affect rows that are already
  # there. The first version of this test ran the seed against an admin mack and
  # asserted he came back a viewer; it passed with the seed's role line DELETED,
  # because User has `before_validation :assign_parked_identity`, which re-applies
  # the parked role on EVERY save. The setup could not create an admin mack in the
  # first place.
  #
  # So the guard belongs on the callback, which is the thing doing the work.
  test "a parked identity cannot be saved into a role the roster contradicts" do
    mack = User.create!(email: "mack@mcritchie.studio", name: "Mack McRitchie", password: "password")

    mack.update!(role: "admin")

    refute mack.reload.admin?,
      "the parked roster must win over a hand-set role, or a demotion never reaches existing rows"
    assert_equal parked("mack@mcritchie.studio")[:role], mack.role
  end

  test "the admins stay admins" do
    run_seed

    User::PARKED_IDENTITIES.select { |identity| identity[:role] == "admin" }.each do |identity|
      assert User.find_by(email: identity[:email]).admin?, "#{identity[:email]} lost admin"
    end
  end
end
