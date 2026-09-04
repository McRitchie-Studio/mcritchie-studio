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
    "alex@mcritchie.studio"  => { name: "Alex McRitchie",  role: "admin",  wallet: true },
    "team@mcritchie.studio"  => { name: "Team McRitchie",  role: "admin",  wallet: true },
    "admin@mcritchie.studio" => { name: "Admin McRitchie", role: "admin",  wallet: false },
    "mason@mcritchie.studio" => { name: "Mason McRitchie", role: "viewer", wallet: true },
    "mack@mcritchie.studio"  => { name: "Mack McRitchie",  role: "viewer", wallet: false },
    "team@turfmonster.media" => { name: "Turf Monster",    role: "viewer", wallet: false }
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

  # THE SUPER-ADMIN SEAT HOLDS NO KEY. admin@mcritchie.studio is the top-of-stack
  # Google credential the Steffon and Alex agents sign in with. Giving it a wallet
  # would put the highest-privilege login in the app on the same identity as a
  # spending account, so the absence is a decision and not an oversight waiting to
  # be tidied up.
  test "the wallet-bearing identities are the ones meant to hold funds" do
    EXPECTED.each do |email, expected|
      assert_equal expected[:wallet], identity(email)[:wallet].present?,
        "#{email} #{expected[:wallet] ? 'lost' : 'gained'} a wallet"
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

  # The wallets are the same keys in both apps; a typo here silently mints a
  # second account for a real person on their next wallet sign-in.
  test "parked wallets are unique across the roster" do
    wallets = User::PARKED_IDENTITIES.filter_map { |i| i[:wallet] }
    assert_equal wallets.uniq, wallets
  end
end
