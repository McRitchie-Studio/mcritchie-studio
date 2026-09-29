# Batched broadcast sends (task broadcast-batch-send): work a list down a
# batch at a time. See Broadcast#send_batch!.
#
#   bin/rails "broadcasts:send_batch[cyvasse-is-back,100]"
#   bin/rails "broadcasts:batch_status[cyvasse-is-back]"
namespace :broadcasts do
  desc "Send a broadcast to N random list contacts it has not reached yet"
  task :send_batch, %i[slug size audience] => :environment do |_t, args|
    broadcast = Broadcast.find_by!(slug: args[:slug])
    audience = args[:audience].presence || broadcast.target_list
    ids = broadcast.send_batch!(size: Integer(args[:size] || 0), audience: audience)
    seconds = (Broadcast::BATCH_SPACING * [ ids.size - 1, 0 ].max).to_i
    puts "#{broadcast.slug}: queued #{ids.size} on #{audience} over about #{seconds}s"
    puts "#{broadcast.slug}: #{broadcast.batch_status(audience).map { |k, v| "#{k} #{v}" }.join(", ")} (sent counts land as jobs run)"
  end

  desc "Where a batched broadcast stands: sent, remaining, opened, clicked"
  task :batch_status, %i[slug audience] => :environment do |_t, args|
    broadcast = Broadcast.find_by!(slug: args[:slug])
    audience = args[:audience].presence || broadcast.target_list
    puts "#{broadcast.slug} on #{audience}: #{broadcast.batch_status(audience).map { |k, v| "#{k} #{v}" }.join(", ")}"
  end
end
