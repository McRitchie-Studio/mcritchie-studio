require_relative "../lib/encoding_sanitizer"

# Sanitize before printing to prevent invalid UTF-8/surrogate chars
# from poisoning stdout (which tools like Claude Code capture).
def safe_puts(str)
  puts EncodingSanitizer.sanitize_utf8(str.to_s)
end

Dir[Rails.root.join("db/seeds/*.rb")].sort.each { |f| load f }

puts "\nSeed complete!"
puts "  Teams: #{Team.count} (NFL: #{Team.nfl.count}, NCAA: #{Team.ncaa.count}, FIFA: #{Team.fifa.count})"
puts "  Arenas: #{Arena.count}"
puts "  People: #{Person.count} (Athletes: #{Person.where(athlete: true).count})"
puts "  Athletes: #{Athlete.count}"
puts "  Contracts: #{Contract.count} (college: #{Contract.where(contract_type: 'college').count}, active: #{Contract.where(contract_type: 'active').count}, draft: #{Contract.where(contract_type: 'draft_pick').count}, mock: #{Contract.where(contract_type: 'mock_pick').count})"
puts "  Seasons: #{Season.count} (active: #{Season.active.count})"
puts "  Slates: #{Slate.count}"
puts "  Rosters: #{Roster.count}, RosterSpots: #{RosterSpot.count}"
puts "  AthleteGrades: #{AthleteGrade.count}"
puts "  Coaches: #{Coach.count} (NFL: #{Coach.where(sport: 'football').count}, FIFA: #{Coach.where(sport: 'soccer').count})"
puts "  CoachRankings: #{CoachRanking.count}"
puts "  TeamRankings: #{TeamRanking.count}"
puts "  ImageCaches: #{ImageCache.count} (athletes with cached headshots: #{Athlete.joins(:image_caches).where(image_caches: { purpose: 'headshot' }).distinct.count})"
