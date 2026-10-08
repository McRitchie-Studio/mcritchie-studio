# The state CHECK constraints (StringStates, StateCheckConstraints).
#
# bin/rails state_checks:census — read-only, run by hand: each registered column's
#   constraint and any value outside its list, tasks.stage NULLs, the values the
#   unconstrained state columns hold, and the devops keys that differ from their
#   column. SELECTs only. Exits non-zero while a constraint is missing, NOT VALID
#   or unlike its list; it is never a deploy hook.
# bin/rails state_checks:apply — the post-deploy hook: add and validate every
#   constraint whose rows are clean, then print the census. Idempotent. It exits
#   0 whatever the rows hold, because the release stops on a hook that fails: a
#   stray value, a NULL stage, a list that differs or a lock not granted prints
#   the UNSETTLED banner and keeps one open triage finding
#   (`state-checks-unsettled`, rewritten each run, dismissed once all settle).
#   Only an unexpected exception exits non-zero.
namespace :state_checks do
  settled = "state checks: every constraint valid, tasks.stage NOT NULL".freeze

  desc "Read-only census of the state columns against their CHECK constraints (values and counts only)"
  task census: :environment do
    census = StateCheckConstraints.new.census
    puts census.lines
    abort "state checks: #{census.unsettled.size} constraint(s) unsettled" \
          "#{"; tasks.stage is nullable" if census.stage_nullable}" unless census.settled?
    puts settled
  end

  desc "Add and validate each state CHECK whose rows are clean, then print the census (exits 0 on any data condition)"
  task apply: :environment do
    service = StateCheckConstraints.new
    census = service.apply
    finding = service.record_signal(census)
    puts census.lines
    if census.settled?
      puts settled
    else
      puts "", "STATE CHECKS UNSETTLED (the rows decide this, so the hook still exits 0):"
      puts census.unsettled_summary.map { |line| "  #{line}" }
      puts "  recorded as triage finding #{finding.slug} (#{finding.status})"
    end
  end
end
