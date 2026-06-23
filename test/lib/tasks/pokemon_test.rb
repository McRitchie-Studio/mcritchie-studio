require "test_helper"
require "rake"

# Integration tier: the `pokemon:backfill_mascots` rake wrapper runs the real
# Task.backfill_mascots! against the DB.
class PokemonBackfillRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("pokemon:backfill_mascots")
    Rake::Task["pokemon:backfill_mascots"].reenable
  end

  test "pokemon:backfill_mascots assigns a mascot to a task lacking one" do
    task = Task.create!(title: "Rake backfill target task") # no Pokémon yet → no mascot
    task.update_column(:metadata, {})
    Pokemon.create!(dex: 143, name: "Snorlax", slug: "snorlax", generation: 1)

    capture_io { Rake::Task["pokemon:backfill_mascots"].invoke }

    assert task.reload.devops["mascot"].present?
  end
end
