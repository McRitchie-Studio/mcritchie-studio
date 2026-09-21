class CreatePersonAppearancesAndArtifacts < ActiveRecord::Migration[8.1]
  def change
    # HOW A PERSON LOOKS in a generated image.
    #
    # This is the generalisation of "colorway", and it is deliberately anchored
    # on Person rather than on a player: the hub models people, not athletes, so
    # a piece can cast Joe Burrow beside Jim Carrey and George Bush. What varies
    # between them is not WHO they are but how they are PRESENTED.
    create_table :appearances do |t|
      t.string :slug, null: false
      t.string :person_slug, null: false

      # "Bengals white" · "navy suit" · "1994 Ace Ventura"
      t.string :descriptor, null: false

      # Only meaningful for athletes, and optional for exactly that reason.
      t.string :team_slug
      t.string :colorway

      # What an image generator works FROM. For an athlete most of this comes
      # free off the Athlete record (build, skin tone, hair, headshot); for
      # everyone else there is no role record at all, so the notes carry it.
      t.string :reference_url
      t.text :generation_notes

      t.datetime :retired_at
      t.timestamps
    end
    add_index :appearances, :slug, unique: true
    add_index :appearances, [:person_slug, :descriptor], unique: true, where: "retired_at IS NULL",
              name: "index_appearances_live_per_person"

    # EVERY person gets a default, set when their first model is created, so the
    # common path never thinks about appearance at all. Changing Burrow from a
    # football player to a man in a suit is then an explicit, later choice.
    add_column :people, :default_appearance_slug, :string
    add_index :people, :default_appearance_slug

    # The generated image itself. It has NO person and NO colorway on it —
    # both live on its subjects, because a mixed-cast image carries three
    # different looks in one frame.
    create_table :artifacts do |t|
      t.string :slug, null: false
      t.string :kind, null: false          # character_sheet | pair | group
      t.string :image_url
      t.string :source                     # chatgpt | higgsfield | upload
      t.datetime :approved_at
      t.string :approved_by
      t.datetime :retired_at
      t.timestamps
    end
    add_index :artifacts, :slug, unique: true
    add_index :artifacts, [:kind, :retired_at]

    # THE JOIN THAT REMOVES THE CEILING. A trio is three rows, not a third
    # column — the previous shape carried `secondary_player_slug` and capped at
    # two, which a three-person cast breaks immediately.
    create_table :artifact_subjects do |t|
      t.string :artifact_slug, null: false
      t.string :person_slug, null: false
      t.string :appearance_slug
      t.string :role                       # qb | skill | any
      t.integer :ordinal, default: 1, null: false
      t.timestamps
    end
    add_index :artifact_subjects, [:artifact_slug, :person_slug], unique: true
    add_index :artifact_subjects, :person_slug
    add_index :artifact_subjects, :appearance_slug

    # The content's cast is likewise a join, not two columns.
    add_column :contents, :artifacts_approved_at, :datetime
  end
end
