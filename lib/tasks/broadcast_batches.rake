# Batched broadcast sends (task broadcast-batch-send): work a list down a
# batch at a time. See Broadcast#send_batch!.
#
#   bin/rails "broadcasts:send_batch[cyvasse-is-back,100]"
#   bin/rails "broadcasts:batch_status[cyvasse-is-back]"
#
# An audience in Broadcast::VERIFIED_AUDIENCES (cyvasse-legacy) sends only to
# contacts verified valid (contacts:verify). ONLY_VERIFIED=1 forces that on any
# audience; ONLY_VERIFIED=0 turns it off.
namespace :broadcasts do
  # ONLY_VERIFIED=1 -> true, 0 -> false, unset -> nil (the audience's default).
  only_verified_flag = lambda do
    case ENV["ONLY_VERIFIED"].to_s
    when "1", "true" then true
    when "0", "false" then false
    end
  end

  desc "Send a broadcast to N random list contacts it has not reached yet"
  task :send_batch, %i[slug size audience] => :environment do |_t, args|
    broadcast = Broadcast.find_by!(slug: args[:slug])
    audience = args[:audience].presence || broadcast.target_list
    verified = only_verified_flag.call
    ids = broadcast.send_batch!(size: Integer(args[:size] || 0), audience: audience, verified: verified)
    seconds = (Broadcast::BATCH_SPACING * [ ids.size - 1, 0 ].max).to_i
    puts "#{broadcast.slug}: queued #{ids.size} on #{audience} over about #{seconds}s"
    only = verified.nil? ? Broadcast.verification_required?(audience) : verified
    puts "#{broadcast.slug}: #{only ? "verified-valid contacts only" : "verification not required"}"
    puts "#{broadcast.slug}: #{broadcast.batch_status(audience, verified: verified).map { |k, v| "#{k} #{v}" }.join(", ")} (sent counts land as jobs run)"
  end

  desc "Where a batched broadcast stands: sent, remaining, opened, clicked"
  task :batch_status, %i[slug audience] => :environment do |_t, args|
    broadcast = Broadcast.find_by!(slug: args[:slug])
    audience = args[:audience].presence || broadcast.target_list
    verified = only_verified_flag.call
    puts "#{broadcast.slug} on #{audience}: #{broadcast.batch_status(audience, verified: verified).map { |k, v| "#{k} #{v}" }.join(", ")}"
  end
end
