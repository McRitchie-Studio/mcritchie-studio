class AddDisambiguatorAndDeltaStamps < ActiveRecord::Migration[8.1]
  def change
    # TWO ACTIVE NFL PLAYERS CAN SHARE A NAME. Six do in the 2026 league, measured
    # against the feed on 2026-09-21 — Justin Jefferson is both a Vikings receiver and a Browns
    # linebacker. Person slugs derive from the name, so without this the second
    # arrival adopts the first's athlete record and OVERWRITES it: one of the
    # two is silently lost, and nothing reports it.
    #
    # NULL for almost everyone. Only a genuine namesake carries one, and the
    # value is a fragment of the league ID rather than a counter, so the slug is
    # stable no matter what order the source rows arrive in.
    add_column :people, :disambiguator, :string

    # DELTA QUERIES. The sync that feeds turf-monster asks
    # `WHERE updated_at > <watermark>`, which is a sequential scan without
    # these. Rails only bumps updated_at on a REAL change, so an idempotent
    # import leaves untouched rows out of the next delta by construction.
    add_index :people, :updated_at
    add_index :athletes, :updated_at
    add_index :teams, :updated_at

    # WHEN THE SOURCE WAS LAST READ, which is a different question from when a
    # record last changed. A record untouched since March is not stale if the
    # import ran this morning and nflverse simply had nothing new for them —
    # without this, record freshness and feed freshness are indistinguishable.
    create_table :import_runs do |t|
      t.string :source, null: false          # nflverse_players | nflverse_schedule
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.string :status, null: false, default: "running"  # running | ok | failed
      t.integer :rows_seen, default: 0
      t.integer :rows_changed, default: 0
      t.text :detail
      t.timestamps
    end
    add_index :import_runs, [:source, :started_at]
  end
end
