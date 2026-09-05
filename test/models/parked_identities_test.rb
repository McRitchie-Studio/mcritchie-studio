require "test_helper"

# THE ROSTER IS A DECISION, NOT A DERIVATION — so it is asserted literally.
#
# Every other test around `PARKED_IDENTITIES` reads a property out of the list
# and checks the list against itself ("some identity is not an admin", "the
# admins stay admins"), which is right for the seed's mechanics and useless for
# the roster's CONTENT: swap two roles and every one of them still passes. This
# file is the operator's list written down a second time, on purpose, so that
# changing who holds admin has to be a deliberate edit in two places.
class ParkedIdentitiesTest < ActiveSupport::TestCase
  # Set by Mr. McRitchie, 2026-09-04.
  EXPECTED = {
    "alex@mcritchie.studio"  => { name: "Alex McRitchie",  role: "admin" },
    "team@mcritchie.studio"  => { name: "Team McRitchie",  role: "admin" },
    "admin@mcritchie.studio" => { name: "Admin McRitchie", role: "admin" },
    "mason@mcritchie.studio" => { name: "Mason McRitchie", role: "viewer" },
    "mack@mcritchie.studio"  => { name: "Mack McRitchie",  role: "viewer" },
    "team@turfmonster.media" => { name: "Turf Monster",    role: "viewer" }
  }.freeze

  def identity(email) = User::PARKED_IDENTITIES.find { |i| i[:email] == email }

  test "the roster holds exactly the parked identities, and no others" do
    assert_equal EXPECTED.keys.sort, User::PARKED_IDENTITIES.map { |i| i[:email] }.sort
  end

  test "each identity carries the name and role the roster assigns it" do
    EXPECTED.each do |email, expected|
      found = identity(email)
      refute_nil found, "#{email} is no longer parked"
      assert_equal expected[:name], found[:name], "#{email} is named wrong"
      assert_equal expected[:role], found[:role], "#{email} holds the wrong role"
    end
  end

  # Both halves matter. A retired address left IN the roster keeps re-seeding the
  # account it was supposed to move off; a replacement missing FROM it means the
  # move points nowhere and `db/seeds/01_users.rb` renames a row onto an address
  # nothing will ever maintain again.
  test "every retired address is gone from the roster and its replacement is in it" do
    refute_empty User::RETIRED_EMAILS

    User::RETIRED_EMAILS.each do |old_email, new_email|
      assert_nil identity(old_email), "#{old_email} is retired but still parked"
      refute_nil identity(new_email), "#{old_email} was moved to #{new_email}, which is not parked"
    end
  end

  test "no address is parked twice" do
    emails = User::PARKED_IDENTITIES.map { |i| i[:email] }
    assert_equal emails.uniq, emails
  end

  # EMAIL IS THE ONLY KEY, and this is the test that says so out loud.
  #
  # `parked_identity_for` used to match on email OR wallet, so an entry could earn
  # its role through either one. /tasks/drop-hub-wallet-column removed the wallet
  # arm along with users.solana_address, which means an identity with no `email:`
  # is now simply never found: no role is applied, no name is planted, and nothing
  # anywhere raises. That silence is the failure mode this test exists to convert
  # into a red build the moment someone parks a keyed-but-emailless seat.
  test "every parked identity is reachable, because email is the only key" do
    User::PARKED_IDENTITIES.each do |parked|
      refute_predicate parked[:email].to_s.strip, :empty?,
        "#{parked[:name].inspect} is parked with no email, so parked_identity_for can never find it"
      assert_equal parked, User.parked_identity_for(email: parked[:email]),
        "#{parked[:email]} does not resolve through the only lookup key it has left"
    end
  end

  # The lookup is case-insensitive on the way in and the roster is stored lowercase;
  # a capitalised entry would resolve for a lowercase sign-in and not for itself.
  test "the roster stores addresses in the case the lookup normalises to" do
    User::PARKED_IDENTITIES.each do |parked|
      assert_equal parked[:email].downcase, parked[:email],
        "#{parked[:email]} is not stored lowercase"
    end
  end
end
