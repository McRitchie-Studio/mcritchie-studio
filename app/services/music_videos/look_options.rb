module MusicVideos
  # The rows of a cast card's look dropdown: each look a performer can be
  # recast into (Appearance.recastable), oldest first, with its newest
  # character sheet as the thumbnail, the default mark, its page, and where
  # its sheet build stands. Three queries, whatever the number of people.
  class LookOptions
    # building: a sheet build is running. ready: a sheet is on file.
    # failed: the last build failed and no sheet is on file. empty: no sheet,
    # nothing running (never built, or a build that went stale).
    STATES = %w[building ready failed empty].freeze

    Option = Data.define(:slug, :descriptor, :default, :image_url, :state, :error, :url)

    # person slug => [Option]. A person with no look has no key.
    def self.for(person_slugs)
      slugs = Array(person_slugs).compact_blank.uniq
      return {} if slugs.empty?

      looks = Appearance.recastable.where(person_slug: slugs).order(:created_at, :id).to_a
      sheets = Artifact.newest_character_sheets(looks.map(&:slug))
      defaults = Person.where(slug: slugs).pluck(:slug, :default_appearance_slug).to_h
      looks.group_by(&:person_slug).transform_values do |mine|
        mine.map { |look| option(look, sheets[look.slug], defaults[look.person_slug]) }
      end
    end

    def self.option(look, sheet, default_slug)
      image_url = sheet&.image_url.presence
      state = state_of(look, image_url)
      Option.new(slug: look.slug, descriptor: look.descriptor, default: look.slug == default_slug,
                 image_url:, state:, error: (look.sheet_build_error.presence if state == "failed"),
                 url: Rails.application.routes.url_helpers.person_appearance_path(look.person_slug, look.slug))
    end

    def self.state_of(look, image_url)
      return "building" if look.sheet_building?
      return "ready" if image_url
      return "failed" if look.sheet_build_failed?

      "empty"
    end
    private_class_method :state_of
  end
end
