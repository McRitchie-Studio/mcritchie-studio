namespace :seed_data do
  desc "Upload a snapshot to the production bucket's seed-data/ (production only). FILE=path NAME=object_name"
  task publish: :environment do
    name = ENV.fetch("NAME") { abort "NAME= is required" }
    sha256 = SeedSnapshot.publish!(ENV.fetch("FILE") { abort "FILE= is required" }, name)
    puts "published #{SeedSnapshot.key(name)} sha256=#{sha256}; pin it in SeedSnapshot::SHA256"
  end
end
