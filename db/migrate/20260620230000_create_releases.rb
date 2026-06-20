class CreateReleases < ActiveRecord::Migration[7.2]
  # The Deploy-workflow coordinator. A Release is the singleton that carries a
  # set of `reviewed` tasks from assembly through ship:
  #   assembling → assembled → shipped   (+ abandoned)
  # See docs/agents/system/devops-cycle-design.md §1.1.
  def up
    create_table :releases do |t|
      t.string   :slug, null: false
      t.string   :state, null: false, default: "assembling"
      t.string   :branch
      t.string   :qa_url
      t.string   :production_url
      t.string   :deployed_sha
      t.datetime :release_notes_sent_at
      t.datetime :confirmed_at
      t.string   :confirmed_by
      t.datetime :assembled_at
      t.datetime :shipped_at
      t.datetime :abandoned_at
      t.jsonb    :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :releases, :slug, unique: true

    # Singleton: at most one ACTIVE (non-terminal) release at a time. A unique
    # index on a constant, restricted to active rows, lets terminal releases pile
    # up while only one assembling/assembled release can exist.
    execute <<~SQL
      CREATE UNIQUE INDEX index_releases_single_active
      ON releases ((1)) WHERE state IN ('assembling', 'assembled')
    SQL

    add_column :tasks, :release_slug, :string
    add_column :tasks, :dependencies, :jsonb, null: false, default: []
    add_index  :tasks, :release_slug
  end

  def down
    remove_column :tasks, :dependencies
    remove_column :tasks, :release_slug
    drop_table :releases
  end
end
