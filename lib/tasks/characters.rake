# frozen_string_literal: true

namespace :characters do
  # Idempotent: creates Turf Monster, his "Classic" look and its kit references
  # when missing, and never overwrites an edit. The post_deploy_cmd of task
  # characters-for-puppet-looks. Generates nothing and spends nothing.
  desc "Seed Turf Monster as the first character, with his Classic look"
  task seed_turf_monster: :environment do
    character = Characters::SeedTurfMonster.call
    look = character.default_appearance
    refs = look ? AppearanceReferencePhoto.where(appearance_slug: look.slug).count : 0
    puts "Character: #{character.slug} (#{character.name}, #{character.kind}, brand #{character.brand})"
    puts "Default look: #{look&.slug || 'none'} #{look&.descriptor} — #{refs} reference image(s)"
  end
end
