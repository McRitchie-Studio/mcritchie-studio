# What a person does (recast pipeline, piece 6): many vocations and one primary,
# which is the one the UI shows. `people.athlete` and `people.coach` stay as
# columns, since the importers write them and the rankings read them in SQL;
# Person keeps the two booleans and the list in step on every save.
#
# The backfill is mechanical and rides this migration (the release phase runs
# db:migrate): athlete and coach from the two booleans, musician from an
# artist linked through artists.person_slug. Nobody is hand-assigned. The
# primary is the first of those three a person holds, in that order; the
# operator changes it on the person page.
#
# The SQL is written out here, not read from Person::VOCATIONS, so the
# migration means the same thing whatever the model later becomes. The
# migration's test holds the two to each other.
class AddVocationsToPeople < ActiveRecord::Migration[8.1]
  def up
    add_column :people, :vocations, :jsonb, null: false, default: []
    add_column :people, :primary_vocation, :string
    add_index :people, :primary_vocation
    backfill
  end

  def down
    remove_index :people, :primary_vocation
    remove_column :people, :primary_vocation
    remove_column :people, :vocations
  end

  private

  def backfill
    execute <<~SQL.squish
      UPDATE people SET vocations =
        (CASE WHEN athlete THEN '["athlete"]'::jsonb ELSE '[]'::jsonb END) ||
        (CASE WHEN coach THEN '["coach"]'::jsonb ELSE '[]'::jsonb END) ||
        (CASE WHEN EXISTS (SELECT 1 FROM artists WHERE artists.person_slug = people.slug)
              THEN '["musician"]'::jsonb ELSE '[]'::jsonb END)
    SQL
    execute "UPDATE people SET primary_vocation = vocations->>0 WHERE jsonb_array_length(vocations) > 0"
  end
end
