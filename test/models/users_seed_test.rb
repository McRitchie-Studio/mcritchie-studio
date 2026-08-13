require "test_helper"

# Exercises db/seeds/01_users.rb directly.
#
# It does NOT run on every deploy in this app: the Procfile release phase is
# `bin/rails db:migrate` alone, and bin/dor-check refuses a bare `db:seed` as a
# post-deploy command. So a roster change reaches a deployed environment through
# `before_validation :assign_parked_identity` on the next save of that account,
# not through this file. What the seed owns is a FRESH database and a local one.
#
# The write-once trap is still worth guarding: find_or_create_by!'s block runs
# only on CREATE, so anything a roster change needs to alter on an EXISTING row
# has to be re-applied explicitly. Role is, via the update! that follows.
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
