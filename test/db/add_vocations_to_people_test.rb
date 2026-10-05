require "test_helper"
require Rails.root.join("db/migrate/20261005120000_add_vocations_to_people")

# [unit] AddVocationsToPeople — the backfill is mechanical: athlete and coach
# from the two booleans, musician from an artist linked through
# artists.person_slug, and the primary is the first of those a person holds.
# Runs the migration's own backfill against rows written without vocations
# (callbacks bypassed, as production holds them). Every person is synthetic.
class AddVocationsToPeopleTest < ActiveSupport::TestCase
  def migration = AddVocationsToPeople.new.tap { |m| m.verbose = false }

  def bare!(last_name, **flags)
    person = Person.create!(first_name: "Test", last_name:)
    person.update_columns(vocations: [], primary_vocation: nil, **flags)
    person
  end

  test "the vocations the backfill writes are ones the model knows, in the model's order" do
    written = %w[athlete coach musician]
    assert_equal written, Person::VOCATIONS & written
    assert_equal %w[athlete coach], Person::FLAG_VOCATIONS
  end

  test "athlete, coach and artist-linked people are backfilled; nobody else is touched" do
    athlete = bare!("Backfill Athlete", athlete: true)
    coach = bare!("Backfill Coach", coach: true)
    musician = bare!("Backfill Musician")
    Artist.insert_all!([{ slug: "test-backfill-musician", name: "Test Backfill Musician", sort_name: "Test Backfill Musician",
                          kind: "person", person_slug: musician.slug }])
    all_three = bare!("Backfill Everything", athlete: true, coach: true)
    Artist.insert_all!([{ slug: "test-backfill-everything", name: "Test Backfill Everything", sort_name: "Test Backfill Everything",
                          kind: "person", person_slug: all_three.slug }])
    nobody = bare!("Backfill Nobody")

    migration.send(:backfill)

    assert_equal [%w[athlete], "athlete"], athlete.reload.values_at(:vocations, :primary_vocation)
    assert_equal [%w[coach], "coach"], coach.reload.values_at(:vocations, :primary_vocation)
    assert_equal [%w[musician], "musician"], musician.reload.values_at(:vocations, :primary_vocation)
    assert_equal [%w[athlete coach musician], "athlete"], all_three.reload.values_at(:vocations, :primary_vocation)
    assert_equal [[], nil], nobody.reload.values_at(:vocations, :primary_vocation)
    [athlete, coach, musician, all_three, nobody].each do |person|
      assert person.valid?, "#{person.slug}: #{person.errors.full_messages.to_sentence}"
      assert_not person.changed?, "#{person.slug}: the model would rewrite what the backfill wrote (#{person.changes})"
    end
  end
end
