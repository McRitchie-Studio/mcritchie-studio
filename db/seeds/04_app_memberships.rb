# The app owners (AppMembership.seed_owners!, docs/agents/system/app-owners.md):
# alex@mcritchie.studio owns McRitchie Studio, alex@turfmonster.media Turf
# Monster, amcritchie@gmail.com Cyvasse. Links only users and apps that exist.
# Idempotent; safe on every run.
AppMembership.seed_owners!.each { |app, outcome| puts "App owner: #{app} #{outcome}" }
