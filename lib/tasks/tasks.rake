namespace :tasks do
  # One-time cutover for the event-driven rank (see Task#ordered). Before this
  # change Task ranked `position ASC` with +1 spacing, so existing rows carry
  # small, densely-packed positions. Under the new `position DESC` + 100-gap
  # scheme those would sort in the WRONG direction, so re-space every task into
  # the new regime: per stage, oldest-created gets the lowest rank and newest the
  # highest, landing the freshest task on top with 100-gaps for future drag
  # inserts. Wired to run on ship via the task's --post-deploy-cmd.
  #
  # Guarded + idempotent: the new scheme only ever writes positions that are
  # multiples of 100, so if the board already looks migrated this NO-OPs rather
  # than clobbering any manual drag-reorders made since the cutover. FORCE=1
  # overrides the guard.
  desc "One-time: re-space Task#position into the 100-gap rank, newest-created on top (idempotent; FORCE=1 to override)."
  task respace_ranks: :environment do
    force = ENV["FORCE"] == "1"

    ranked = Task.where.not(position: nil)
    aligned = ranked.where("position % 100 = 0 AND position > 0").count
    if !force && ranked.count.positive? && aligned >= (ranked.count / 2.0)
      puts "tasks:respace_ranks — board already on the 100-gap rank " \
           "(#{aligned}/#{ranked.count} aligned). Skipping. Re-run with FORCE=1 to override."
      next
    end

    updated = 0
    stages = Task.distinct.pluck(:stage).compact
    stages.each do |stage|
      Task.where(stage: stage).order(created_at: :asc).each_with_index do |task, idx|
        # update_column: skip callbacks so set_stage_timestamp doesn't re-bump.
        task.update_column(:position, (idx + 1) * 100)
        updated += 1
      end
    end

    puts "tasks:respace_ranks — re-spaced #{updated} task(s) across #{stages.size} stage(s)."
  end
end
