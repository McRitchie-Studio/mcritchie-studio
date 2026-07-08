# frozen_string_literal: true

namespace :tasks do
  desc "Backfill/refresh the per-task testing-phase projection (Task::TestingPhases) for every task"
  task backfill_testing_phases: :environment do
    count = Task::TestingPhases.backfill!
    puts "testing-phase projection refreshed for #{count} task(s)"
  end
end
