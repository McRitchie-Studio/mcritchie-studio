# The state CHECK constraints (StringStates, StateCheckConstraints).
#
# bin/rails state_checks:census — read-only: each registered column's constraint
#   and any value outside its list, tasks.stage NULLs, the values the unconstrained
#   state columns hold, and the devops keys that differ from their column. SELECTs
#   only. Exits non-zero while a constraint is missing, NOT VALID or unlike its list.
# bin/rails state_checks:apply — the post-deploy step: add and validate every
#   constraint whose rows are clean, then print the census. Idempotent. Exits
#   non-zero while anything is left.
namespace :state_checks do
  report = lambda do |census|
    puts census.lines
    abort "state checks: #{census.unsettled.size} constraint(s) unsettled" \
          "#{"; tasks.stage is nullable" if census.stage_nullable}" unless census.settled?
    puts "state checks: every constraint valid, tasks.stage NOT NULL"
  end

  desc "Read-only census of the state columns against their CHECK constraints (values and counts only)"
  task census: :environment do
    report.call(StateCheckConstraints.new.census)
  end

  desc "Add and validate each state CHECK whose rows are clean, then print the census"
  task apply: :environment do
    report.call(StateCheckConstraints.new.apply)
  end
end
