# Music artists (people and groups), seeded from Wikidata. Slug FKs, no DB
# foreign keys, like the rest of the app. `person_slug` links an individual to
# `people` and is set by an operator, never by the seed.
class CreateArtists < ActiveRecord::Migration[8.1]
  def change
    create_table :artists do |t|
      t.string :slug, null: false
      t.string :name, null: false
      t.string :sort_name, null: false
      t.string :kind, null: false # person | group
      t.string :person_slug
      t.string :wikidata_id
      t.string :musicbrainz_id
      t.string :discogs_id
      t.string :spotify_id
      t.timestamps
    end
    add_index :artists, :slug, unique: true
    add_index :artists, :wikidata_id, unique: true
    add_index :artists, :person_slug
    add_index :artists, :musicbrainz_id
    add_index :artists, :spotify_id
    add_index :artists, :name

    create_table :artist_aliases do |t|
      t.string :artist_slug, null: false
      t.string :name, null: false
      t.string :locale, null: false, default: "en"
      t.timestamps
    end
    add_index :artist_aliases, [:artist_slug, :name, :locale], unique: true
    add_index :artist_aliases, :name

    # One row per stint: a member who left and rejoined has two.
    create_table :artist_memberships do |t|
      t.string :member_artist_slug, null: false
      t.string :group_artist_slug, null: false
      t.integer :start_year
      t.integer :end_year
      t.timestamps
    end
    add_index :artist_memberships, "member_artist_slug, group_artist_slug, COALESCE(start_year, 0)",
              unique: true, name: "index_artist_memberships_on_stint"
    add_index :artist_memberships, :group_artist_slug
  end
end
