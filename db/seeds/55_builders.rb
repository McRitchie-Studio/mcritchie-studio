seeded_builders = [
  {
    github_login: "YungIrishNigerian",
    github_name: "YungIrishNigerian",
    first_name: "YungIrishNigerian",
    last_name: "Builder",
    location: nil,
    avatar_url: "https://avatars.githubusercontent.com/u/92494002?v=4",
    website_url: nil,
    email: nil,
    linkedin_url: nil,
    x_url: nil,
    instagram_url: nil,
    facebook_url: nil,
    github_profile_url: "https://github.com/YungIrishNigerian",
    github_company: nil,
    github_bio: nil,
    github_blog: nil,
    github_email: nil,
    github_twitter_username: nil,
    source_rank: nil,
    source_contributions: nil,
    raw_profile: {
      login: "YungIrishNigerian",
      id: 92494002,
      html_url: "https://github.com/YungIrishNigerian",
      avatar_url: "https://avatars.githubusercontent.com/u/92494002?v=4",
      name: nil,
      company: nil,
      blog: "",
      location: nil,
      email: nil,
      bio: nil,
      twitter_username: nil,
      public_repos: 0,
      followers: 1,
      following: 0,
      created_at: "2021-10-14T01:13:29Z",
      updated_at: "2026-05-27T23:27:27Z"
    }
  },
  {
    github_login: "amcritchie",
    github_name: "Alex McRitchie",
    first_name: "Alex",
    last_name: "McRitchie",
    location: nil,
    avatar_url: "https://avatars.githubusercontent.com/u/7839245?v=4",
    website_url: nil,
    email: nil,
    linkedin_url: nil,
    x_url: nil,
    instagram_url: nil,
    facebook_url: nil,
    github_profile_url: "https://github.com/amcritchie",
    github_company: nil,
    github_bio: "Director of Software Engineering at PlanOmatic with a passion for leading strong teams and scalable technology that is a delight to engage with.",
    github_blog: nil,
    github_email: nil,
    github_twitter_username: nil,
    source_rank: nil,
    source_contributions: nil,
    raw_profile: {
      login: "amcritchie",
      id: 7839245,
      html_url: "https://github.com/amcritchie",
      avatar_url: "https://avatars.githubusercontent.com/u/7839245?v=4",
      name: "Alex McRitchie",
      company: nil,
      blog: "",
      location: nil,
      email: nil,
      bio: "Director of Software Engineering at PlanOmatic with a passion for leading strong teams and scalable technology that is a delight to engage with.",
      twitter_username: nil,
      public_repos: 127,
      followers: 17,
      following: 38,
      created_at: "2014-06-09T14:41:04Z",
      updated_at: "2026-05-15T23:19:31Z"
    }
  },
  {
    github_login: "lucasmccomb",
    github_name: "Lucas McComb",
    first_name: "Lucas",
    last_name: "McComb",
    location: "Brooklyn, NY",
    avatar_url: "https://avatars.githubusercontent.com/u/5007314?v=4",
    website_url: "https://lem.work",
    email: nil,
    linkedin_url: nil,
    x_url: nil,
    instagram_url: nil,
    facebook_url: nil,
    github_profile_url: "https://github.com/lucasmccomb",
    github_company: nil,
    github_bio: "Software Engineer",
    github_blog: "lem.work",
    github_email: nil,
    github_twitter_username: nil,
    source_rank: nil,
    source_contributions: nil,
    raw_profile: {
      login: "lucasmccomb",
      id: 5007314,
      html_url: "https://github.com/lucasmccomb",
      avatar_url: "https://avatars.githubusercontent.com/u/5007314?v=4",
      name: "Lucas McComb",
      company: nil,
      blog: "lem.work",
      location: "Brooklyn, NY",
      email: nil,
      bio: "Software Engineer",
      twitter_username: nil,
      public_repos: 9,
      followers: 12,
      following: 4,
      created_at: "2013-07-14T14:54:31Z",
      updated_at: "2026-02-21T17:53:13Z"
    }
  }
]

seeded_builders.each do |data|
  github_login = data[:github_login].downcase
  person = Builder.find_by(github_login: github_login)&.person ||
    Person.find_or_create_by_name!(data[:first_name], data[:last_name])

  person.assign_attributes({
    location: data[:location],
    avatar_url: data[:avatar_url],
    website_url: data[:website_url],
    email: data[:email],
    linkedin_url: data[:linkedin_url],
    x_url: data[:x_url],
    instagram_url: data[:instagram_url],
    facebook_url: data[:facebook_url]
  }.compact_blank)
  person.save! if person.changed?

  builder = Builder.find_or_initialize_by(github_login: github_login)
  builder.assign_attributes(
    person: person,
    github_profile_url: data[:github_profile_url],
    github_avatar_url: data[:avatar_url],
    github_name: data[:github_name],
    github_company: data[:github_company],
    github_bio: data[:github_bio],
    github_blog: data[:github_blog],
    github_email: data[:github_email],
    github_twitter_username: data[:github_twitter_username],
    primary_language: nil,
    source_dataset: "manual_builder_seed",
    source_url: data[:github_profile_url],
    source_rank: data[:source_rank],
    source_contributions: data[:source_contributions],
    active: true,
    raw_profile: data[:raw_profile]
  )
  builder.save!

  tracked = TrackedGithubBuilder.find_or_initialize_by(github_login: builder.github_login)
  tracked.assign_attributes(
    display_name: builder.display_name,
    cohort: "ai_builder",
    category: "manual_monitor",
    notes: "Owner-requested seeded GitHub builder. Public GitHub profile data only; review cohort before publishing analysis.",
    active: true
  )
  tracked.save!
end

puts "Seeded GitHub builders: #{seeded_builders.size}"
