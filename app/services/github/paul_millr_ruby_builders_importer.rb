module Github
  class PaulMillrRubyBuildersImporter
    DEFAULT_LANGUAGE = "Ruby".freeze
    SOURCE_DATASET = "paulmillr_active_github_users".freeze

    def initialize(source_importer: PaulMillrActiveUsersImporter.new, client: Client.new, logger: Rails.logger)
      @source_importer = source_importer
      @client = client
      @logger = logger
    end

    def import!(url: PaulMillrActiveUsersImporter::DEFAULT_URL, language: DEFAULT_LANGUAGE,
      max: nil, active: true, enrich_profiles: true, tracked_cohort: "control_builder")
      users = @source_importer.users(url: url).select { |user| user.language.to_s.casecmp?(language) }
      users = users.first(max.to_i) if max.to_i.positive?

      result = { source_url: url, language: language, seen: users.size, created: 0, updated: 0, profiles_enriched: 0, profile_errors: 0 }

      users.each do |user|
        profile = enrich_profiles ? fetch_profile(user.github_login, result) : {}
        person = upsert_person(user, profile)
        builder = Builder.find_or_initialize_by(github_login: user.github_login)
        result[builder.new_record? ? :created : :updated] += 1

        builder.assign_attributes(builder_attributes(user, profile, person, url, active))
        builder.save!
        upsert_tracked_builder(builder, user, tracked_cohort, active, url)
      end

      @logger&.info("Imported Paul Miller Ruby GitHub builders #{result.inspect}")
      result
    end

    private

    def fetch_profile(github_login, result)
      profile = @client.get("/users/#{github_login}")
      result[:profiles_enriched] += 1
      profile
    rescue Github::Client::HttpError => e
      result[:profile_errors] += 1
      @logger&.warn("GitHub builder profile enrichment failed login=#{github_login} error=#{e.class}: #{e.message}")
      {}
    end

    def upsert_person(user, profile)
      name = profile["name"].presence || user.name.presence || user.github_login
      first_name, last_name = split_name(name, user.github_login)
      person = Builder.find_by(github_login: user.github_login)&.person ||
        Person.find_or_create_by_name!(first_name, last_name)

      person.assign_attributes(person_attributes(user, profile))
      person.save! if person.changed?
      person
    end

    def split_name(name, fallback)
      parts = name.to_s.squish.split(/\s+/, 2)
      first_name = parts.first.presence || fallback
      last_name = parts.second.presence || fallback
      [first_name, last_name]
    end

    def person_attributes(user, profile)
      website = normalized_url(profile["blog"])
      twitter = profile["twitter_username"].presence

      {
        location: profile["location"].presence || user.location.presence,
        avatar_url: profile["avatar_url"].presence,
        website_url: website,
        email: profile["email"].presence,
        x_url: twitter ? "https://x.com/#{twitter}" : nil
      }.compact_blank
    end

    def builder_attributes(user, profile, person, url, active)
      {
        person: person,
        github_profile_url: profile["html_url"].presence || "https://github.com/#{user.github_login}",
        github_avatar_url: profile["avatar_url"].presence,
        github_name: profile["name"].presence || user.name.presence,
        github_company: profile["company"].presence,
        github_bio: profile["bio"].presence,
        github_blog: profile["blog"].presence,
        github_email: profile["email"].presence,
        github_twitter_username: profile["twitter_username"].presence,
        primary_language: user.language.presence,
        source_dataset: SOURCE_DATASET,
        source_url: url,
        source_rank: user.rank,
        source_contributions: user.contributions,
        active: active,
        raw_profile: profile.presence || {}
      }
    end

    def upsert_tracked_builder(builder, user, tracked_cohort, active, url)
      tracked = TrackedGithubBuilder.find_or_initialize_by(github_login: builder.github_login)
      tracked.assign_attributes(
        display_name: builder.display_name,
        cohort: tracked.cohort.presence || tracked_cohort,
        category: "ruby_builder",
        active: active,
        notes: tracked.notes.presence || tracked_notes(user, url)
      )
      tracked.save!
    end

    def tracked_notes(user, url)
      [
        "Paul Miller historic active GitHub user list Ruby candidate.",
        "2012-2013 public contribution rank ##{user.rank}",
        "#{user.contributions} contributions",
        "language: #{user.language}",
        ("location: #{user.location}" if user.location.present?),
        "source: #{url}"
      ].compact.join(". ")
    end

    def normalized_url(value)
      url = value.to_s.strip
      return nil if url.blank?

      url.match?(%r{\Ahttps?://}i) ? url : "https://#{url}"
    end
  end
end
