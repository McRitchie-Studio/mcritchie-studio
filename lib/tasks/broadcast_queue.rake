# The staged email queue (task staged-email-queue): render each reader's email
# and hold it, approve what should go, then send only what was approved. The
# same queue is at /broadcasts/<slug>/queue.
#
#   bin/rails "broadcasts:stage[your-games,cyvasse-legacy,200]"   # render + hold; sends nothing
#   bin/rails "broadcasts:restage[your-games]"                    # re-render every staged row with today's copy
#   bin/rails "broadcasts:approve[your-games,50]"                 # approve the 50 longest held (or all)
#   bin/rails "broadcasts:execute[your-games,50]"                 # send up to 50 approved, within the gate
#   bin/rails "broadcasts:queue_status[your-games]"
#
# An audience in Broadcast::VERIFIED_AUDIENCES stages only verified-valid
# contacts; ONLY_VERIFIED=1/0 overrides that, as for broadcasts:send_batch.
namespace :broadcasts do
  queue_line = lambda do |broadcast|
    counts = broadcast.queue_counts.map { |k, v| "#{k} #{v}" }.join(", ")
    reasons = broadcast.skip_reasons.map { |r, n| "#{r} (#{n})" }.join("; ")
    "#{broadcast.slug}: #{counts}#{" — skipped: #{reasons}" if reasons.present?}"
  end

  desc "Render and hold a broadcast for up to LIMIT contacts on AUDIENCE (sends nothing)"
  task :stage, %i[slug audience limit] => :environment do |_t, args|
    broadcast = Broadcast.find_by!(slug: args[:slug])
    audience = args[:audience].presence || broadcast.target_list
    verified = { "1" => true, "true" => true, "0" => false, "false" => false }[ENV["ONLY_VERIFIED"].to_s]
    result = broadcast.stage!(audience: audience, limit: args[:limit].presence&.then { Integer(_1) }, verified: verified)
    puts "#{broadcast.slug}: staged #{result.staged}, skipped #{result.skipped} on #{audience} (nothing sent)"
    puts queue_line.call(broadcast)
  end

  desc "Re-render every staged (not approved, sent or cancelled) email of a broadcast with the current copy"
  task :restage, %i[slug] => :environment do |_t, args|
    broadcast = Broadcast.find_by!(slug: args[:slug])
    result = broadcast.restage!
    puts "#{broadcast.slug}: restaged #{result.restaged}, skipped #{result.skipped}, " \
         "left #{result.left} (approved, sent and cancelled rows untouched; nothing sent)"
    puts queue_line.call(broadcast)
  end

  desc "Approve the COUNT longest-held staged emails of a broadcast (all when blank or 'all')"
  task :approve, %i[slug count] => :environment do |_t, args|
    broadcast = Broadcast.find_by!(slug: args[:slug])
    count = args[:count].to_s.then { _1.blank? || _1 == "all" ? nil : Integer(_1) }
    puts "#{broadcast.slug}: approved #{broadcast.approve_staged!(count: count)}"
    puts queue_line.call(broadcast)
  end

  desc "Send up to LIMIT approved staged emails of a broadcast, within the daily cap and send gate"
  task :execute, %i[slug limit] => :environment do |_t, args|
    broadcast = Broadcast.find_by!(slug: args[:slug])
    result = broadcast.execute_staged!(limit: Integer(args[:limit] || 0))
    gate = result.gate
    puts "gate: #{gate.paused? ? "PAUSED — #{gate.reasons.join('; ')}" : 'open'} · " \
         "#{gate.sent}/#{gate.daily_cap} in the last 24h · bounces #{gate.bounces} · complaints #{gate.complaints}"
    puts "#{broadcast.slug}: queued #{result.queued} to send over about #{(Broadcast::BATCH_SPACING * [ result.queued - 1, 0 ].max).to_i}s"
    puts queue_line.call(broadcast)
  end

  desc "Where a broadcast's staged queue stands"
  task :queue_status, %i[slug] => :environment do |_t, args|
    puts queue_line.call(Broadcast.find_by!(slug: args[:slug]))
  end
end
