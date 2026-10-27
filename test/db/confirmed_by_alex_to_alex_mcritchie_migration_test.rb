require "test_helper"
require Rails.root.join("db/migrate/20261027120000_confirmed_by_alex_to_alex_mcritchie.rb").to_s
require Rails.root.join("bin/lib/ship_authority").to_s

# [db] ConfirmedByAlexToAlexMcritchie names the owner on the releases the Mac-login
# default stamped `alex` after `alex` stopped being a soul slug (2026-09-25), and
# only those: an `alex` row confirmed before the cutoff came through the soul
# renames (alex → xan → ray → alex) and is left as the renames ruled it, every
# other confirmer is untouched, and `down` restores exactly the rows `up` changed —
# never an owner confirmation written after it.
class ConfirmedByAlexToAlexMcritchieMigrationTest < ActiveSupport::TestCase
  M = ConfirmedByAlexToAlexMcritchie

  def migrate(direction) = capture_io { M.new.public_send(direction) }

  def release(slug, by, at)
    Release.create!(slug: slug, state: "shipped", branch: "release", confirmed_by: by, confirmed_at: at)
  end

  setup do
    @login    = release("rel-mig-login", "alex", Time.utc(2026, 10, 14, 2, 54))
    @first    = release("rel-mig-first", "alex", M::CUTOFF)
    @renamed  = release("rel-mig-renamed", "alex", Time.utc(2026, 9, 24, 5, 23))
    @conductor = release("rel-mig-conductor", "conductor", Time.utc(2026, 10, 2))
    @unconfirmed = release("rel-mig-none", nil, nil)
  end

  test "the owner's name is one value across the migration, ship authority and the owner person" do
    assert_equal AgentPerson::OWNER[:name], M::OWNER
    assert_equal AgentPerson::OWNER[:name], ShipAuthority::OWNER
  end

  test "up names the owner on post-cutoff alex rows only, and marks what it changed" do
    migrate(:up)

    assert_equal "Alex McRitchie", @login.reload.confirmed_by
    assert_equal "Alex McRitchie", @first.reload.confirmed_by, "the cutoff is inclusive"
    assert_equal "alex", @login.metadata[M::MARK], "up records what the row held"
    assert_equal "alex", @renamed.reload.confirmed_by, "a soul-rename row keeps the renames' ruling"
    refute @renamed.metadata.key?(M::MARK)
    assert_equal "conductor", @conductor.reload.confirmed_by
    assert_nil @unconfirmed.reload.confirmed_by
  end

  test "a second up changes nothing" do
    migrate(:up)
    before = Release.where(slug: %w[rel-mig-login rel-mig-first rel-mig-renamed]).pluck(:slug, :confirmed_by, :metadata)
    migrate(:up)
    assert_equal before, Release.where(slug: %w[rel-mig-login rel-mig-first rel-mig-renamed]).pluck(:slug, :confirmed_by, :metadata)
  end

  test "down restores only the rows up changed" do
    migrate(:up)
    later = release("rel-mig-later", "Alex McRitchie", Time.utc(2026, 10, 28))

    migrate(:down)

    assert_equal "alex", @login.reload.confirmed_by
    refute @login.metadata.key?(M::MARK), "down clears its mark"
    assert_equal "alex", @first.reload.confirmed_by
    assert_equal "Alex McRitchie", later.reload.confirmed_by, "an owner confirmation written after up is not up's to undo"
    assert_equal "alex", @renamed.reload.confirmed_by
    assert_equal "conductor", @conductor.reload.confirmed_by
  end

  test "up keeps the rest of a row's metadata" do
    @login.update_columns(metadata: { "rolled_back" => { "at" => "x" } })
    migrate(:up)
    assert_equal({ "rolled_back" => { "at" => "x" }, M::MARK => "alex" }, @login.reload.metadata)
    migrate(:down)
    assert_equal({ "rolled_back" => { "at" => "x" } }, @login.reload.metadata)
  end
end
