require "test_helper"

class Github::PaulMillrRubyBuildersImporterTest < ActiveSupport::TestCase
  User = Github::PaulMillrActiveUsersImporter::User

  FakeSource = Struct.new(:users_list) do
    def users(url:)
      users_list
    end
  end

  FakeClient = Struct.new(:profiles) do
    def get(path)
      profiles.fetch(path)
    end
  end

  test "imports only Ruby builders into people builders and tracked builders" do
    ruby_user = User.new(
      rank: 12,
      github_login: "matz",
      name: "Yukihiro Matsumoto",
      contributions: 1234,
      language: "Ruby",
      location: "Japan"
    )
    js_user = User.new(
      rank: 13,
      github_login: "not-ruby",
      name: "Not Ruby",
      contributions: 999,
      language: "JavaScript",
      location: "Internet"
    )
    client = FakeClient.new({
      "/users/matz" => {
        "name" => "Yukihiro Matsumoto",
        "avatar_url" => "https://avatars.githubusercontent.com/u/1?v=4",
        "html_url" => "https://github.com/matz",
        "blog" => "ruby-lang.org",
        "location" => "Matsue, Japan",
        "email" => "matz@example.com",
        "twitter_username" => "yukihiro_matz",
        "company" => "Ruby",
        "bio" => "Ruby creator"
      }
    })
    importer = Github::PaulMillrRubyBuildersImporter.new(
      source_importer: FakeSource.new([ruby_user, js_user]),
      client: client,
      logger: nil
    )

    result = importer.import!(url: "https://example.com/active.md")

    assert_equal 1, result[:seen]
    assert_equal 1, result[:created]
    assert_equal 1, result[:profiles_enriched]
    assert_equal 0, result[:profile_errors]

    builder = Builder.find_by!(github_login: "matz")
    assert_equal "Ruby", builder.primary_language
    assert_equal 12, builder.source_rank
    assert_equal 1234, builder.source_contributions
    assert_equal "https://github.com/matz", builder.github_profile_url
    assert_equal "Ruby creator", builder.github_bio

    person = builder.person
    assert_equal "Yukihiro Matsumoto", person.full_name
    assert_equal "Matsue, Japan", person.location
    assert_equal "https://avatars.githubusercontent.com/u/1?v=4", person.avatar_url
    assert_equal "https://ruby-lang.org", person.website_url
    assert_equal "matz@example.com", person.email
    assert_equal "https://x.com/yukihiro_matz", person.x_url

    tracked = TrackedGithubBuilder.find_by!(github_login: "matz")
    assert_equal "control_builder", tracked.cohort
    assert_equal "ruby_builder", tracked.category
    assert tracked.active?

    assert_nil Builder.find_by(github_login: "not-ruby")
  end

  test "is idempotent for existing builder records" do
    user = User.new(
      rank: 1,
      github_login: "rubyist",
      name: "Ruby I St",
      contributions: 10,
      language: "Ruby",
      location: "Earth"
    )
    importer = Github::PaulMillrRubyBuildersImporter.new(
      source_importer: FakeSource.new([user]),
      client: FakeClient.new({ "/users/rubyist" => {} }),
      logger: nil
    )

    assert_difference -> { Builder.count }, 1 do
      importer.import!(url: "https://example.com/active.md")
    end
    assert_no_difference -> { Builder.count } do
      importer.import!(url: "https://example.com/active.md")
    end
    assert_equal 1, TrackedGithubBuilder.where(github_login: "rubyist").count
  end
end
