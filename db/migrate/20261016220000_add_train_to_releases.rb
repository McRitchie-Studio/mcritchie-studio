# Per-app release trains, task A (release-trains-design.md §2): a release now
# belongs to a train, and "at most one active release" holds per train instead of
# globally. Every existing row, and every row old code writes, is the "hub" train.
#
# Live-table safety:
# - add_column with a constant default is a metadata-only change on Postgres 11+;
#   no table rewrite, and old code that never names `train` writes "hub".
# - The index swap runs in the migration's transaction, so there is no moment with
#   neither constraint: the new index is built, the old one dropped, and the new one
#   takes the old name (so the guard catalog and the index-bites test still name it).
#   `releases` holds a few hundred rows, so the brief lock is cheap; a CONCURRENTLY
#   build would leave a window with no singleton guard at all.
# - (train) is strictly weaker than (1) for one train: while every row is "hub" the
#   two indexes refuse exactly the same writes.
class AddTrainToReleases < ActiveRecord::Migration[8.1]
  ACTIVE = "((state)::text = ANY (ARRAY[('assembling'::character varying)::text, ('assembled'::character varying)::text]))".freeze

  def up
    add_column :releases, :train, :string, null: false, default: "hub"
    add_index :releases, :train, unique: true, where: ACTIVE, name: "index_releases_single_active_per_train"
    remove_index :releases, name: "index_releases_single_active"
    rename_index :releases, "index_releases_single_active_per_train", "index_releases_single_active"
  end

  def down
    # The global singleton cannot be restored over two active trains, and must not
    # be by silently abandoning one: refuse, naming them, and change nothing.
    active = select_values("SELECT slug FROM releases WHERE #{ACTIVE} ORDER BY slug")
    if active.size > 1
      raise ActiveRecord::IrreversibleMigration,
            "releases: #{active.size} active releases (#{active.join(', ')}); finish or abandon all but one before rolling back"
    end

    add_index :releases, "(1)", unique: true, where: ACTIVE, name: "index_releases_single_active_global"
    remove_index :releases, name: "index_releases_single_active"
    rename_index :releases, "index_releases_single_active_global", "index_releases_single_active"
    remove_column :releases, :train
  end
end
