require "test_helper"

class Github::PaulMillrActiveUsersImporterTest < ActiveSupport::TestCase
  SAMPLE = <<~HTML
    <tr><th scope="row">#1</th><td><a href="https://github.com/visionmedia">visionmedia</a> (TJ Holowaychuk)</td><td>7458</td><td>JavaScript</td><td>Victoria, BC, Canada</td><td></td></tr>
    <tr><th scope="row">#2</th><td><a href="https://github.com/fabpot">fabpot</a> (Fabien Potencier)</td><td>6743</td><td>PHP</td><td>Paris, France</td><td></td></tr>
  HTML

  test "parses active user rows from the Paul Miller gist html table" do
    users = Github::PaulMillrActiveUsersImporter.new.parse(SAMPLE)

    assert_equal 2, users.size
    assert_equal "visionmedia", users.first.github_login
    assert_equal "TJ Holowaychuk", users.first.name
    assert_equal 7458, users.first.contributions
    assert_equal "JavaScript", users.first.language
  end

  test "imports users as control candidates and preserves existing builders" do
    TrackedGithubBuilder.create!(
      github_login: "visionmedia",
      display_name: "Existing Builder",
      cohort: "ai_builder",
      category: "existing",
      notes: "keep this note",
      active: false
    )
    importer = Github::PaulMillrActiveUsersImporter.new(http_get: ->(_url) { SAMPLE }, logger: nil)

    result = importer.import!(url: "https://example.com/active.md", max: 2)

    assert_equal 2, result[:seen]
    assert_equal 1, result[:created]
    assert_equal 1, result[:existing_preserved]

    existing = TrackedGithubBuilder.find_by!(github_login: "visionmedia")
    assert_equal "ai_builder", existing.cohort
    assert_equal "Existing Builder", existing.display_name
    assert_equal "keep this note", existing.notes
    assert existing.active?

    created = TrackedGithubBuilder.find_by!(github_login: "fabpot")
    assert_equal "control_builder", created.cohort
    assert_equal "historic_prolific_github", created.category
    assert_includes created.notes, "rank #2"
  end
end
