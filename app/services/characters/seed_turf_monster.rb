# frozen_string_literal: true

module Characters
  # TURF MONSTER, THE FIRST OF THE CAST — idempotent, so it is the task's
  # post_deploy_cmd (`bin/rails characters:seed_turf_monster`) rather than a
  # migration data step.
  #
  # CREATES WHAT IS MISSING AND NEVER OVERWRITES. The bio and personality are a
  # DRAFT for Alex (drafted from the Turf brand kit's style text, the mascot art
  # and docs/agents/agents/turf_monster/soul.md); once he edits them on
  # /characters/turf-monster, a re-run leaves his words alone.
  #
  # The first look, "Classic", takes the kit's own references as its art: the
  # mascot (public/agents/turf-monster.webp) and the style anchor (Turf's welcome
  # banner). Each is stored once in our bucket and recognised on a re-run by its
  # title. NO SHEET IS GENERATED HERE: piece B builds his turnaround with Alex.
  class SeedTurfMonster
    SLUG = "turf-monster"
    LOOK = "Classic"
    DRAFT = "[Draft for Alex] "

    ATTRIBUTES = {
      name: "Turf Monster",
      kind: "mascot",
      brand: "turf-monster",
      avatar_url: "/agents/turf-monster.webp",
      bio: "#{DRAFT}Turf Monster is the green, furry gator who lives under the stadium lights and runs " \
           "Turf Monster, the sports pick'em app. He knows every team, every player and every stat line, " \
           "and he is the face of every Turf email, video and post.",
      personality: "#{DRAFT}Big-hearted, loud and competitive. Grins first and talks fast; gets genuinely " \
                   "excited about a well-set line and a close game. Plays fair and wants every match to be fun. " \
                   "Celebrates with his arms thrown wide.",
      voice_notes: "#{DRAFT}Sports metaphors, short punchy lines, never mean. Explains the numbers in plain words."
    }.freeze

    LOOK_NOTES = "A green furry gator mascot: shaggy spiked fur on the head and back, a long rounded gator " \
                 "snout with two nostrils, big white eyes with dark green pupils, a wide friendly grin with a " \
                 "few white teeth. Dark green outlines and a lightly textured flat-cartoon finish. In the " \
                 "classic outfit: light-green polo shirt, dark-green shorts, dark-green socks and black cleats."

    # The kit's references, in the order the sheet sends them.
    KIT_REFERENCES = [
      { path: "public/agents/turf-monster.webp", label: "Kit mascot (public/agents/turf-monster.webp)" },
      { path: "public/email_brand/turf-monster-style-anchor.jpg",
        label: "Kit style anchor (public/email_brand/turf-monster-style-anchor.jpg)" }
    ].freeze

    def self.call(**kwargs) = new(**kwargs).call

    # `store:` is (bytes, content_type) -> url; the default files our copy in the
    # bucket. The e2e seed passes one that answers the public path instead.
    def initialize(store: nil, root: Rails.root)
      @store = store || method(:store_in_bucket)
      @root = root
    end

    def call
      Character.transaction do
        character = Character.find_or_create_by!(slug: SLUG) { |c| c.assign_attributes(ATTRIBUTES) }
        look = character.appearances.live.find_by(descriptor: LOOK) ||
               character.appearances.create!(descriptor: LOOK, generation_notes: LOOK_NOTES)
        KIT_REFERENCES.each_with_index { |ref, i| file_reference(look, ref, i) }
        character.resolve_default_appearance!
        character
      end
    end

    private

    def file_reference(look, ref, position)
      return if AppearanceReferencePhoto.exists?(appearance_slug: look.slug, title: ref[:label])

      bytes = File.binread(@root.join(ref[:path]))
      content_type = EmailBrandReference.content_type_of(bytes)
      raise ArgumentError, "#{ref[:path]} is not a PNG, JPEG or WebP" if content_type.nil?

      AppearanceReferencePhoto.create!(appearance_slug: look.slug, source: AppearanceReferencePhoto::SOURCE_UPLOAD,
                                       chosen: true, title: ref[:label], mime_type: content_type,
                                       position: position, image_url: @store.call(bytes, content_type))
    end

    def store_in_bucket(bytes, content_type)
      UploadLookArt.store_bytes(bytes, content_type: content_type, character_slug: SLUG)
    end
  end
end
