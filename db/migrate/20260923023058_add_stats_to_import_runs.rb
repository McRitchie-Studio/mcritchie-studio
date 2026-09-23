# frozen_string_literal: true

# The run's own tally, kept WITH the run.
#
# `import_runs` already answered "when was the source last read" and "how many
# rows moved", but the importer collected a great deal more than that and threw
# all of it away at the end of the process: Nflverse::SeedPlayers builds a
# `@stats` hash counting every skip it made — inactive rows, rows below the
# season floor, rows with no name, and the one that matters most, the namesakes
# its identity guard REFUSED to write — and `run.update!` persisted only
# rows_seen and rows_changed. So a human the importer deliberately declined to
# create existed afterwards only as a release-phase log line, which ages out of
# Heroku. "Did we drop anyone last import, and who" had no answer a week later.
#
# jsonb rather than columns: the payload is the importer's vocabulary, it
# differs per source (nflverse_players and nflverse_schedule do not count the
# same things), and a counter added next month should not owe a migration.
class AddStatsToImportRuns < ActiveRecord::Migration[8.0]
  def change
    add_column :import_runs, :stats, :jsonb, default: {}, null: false
  end
end
