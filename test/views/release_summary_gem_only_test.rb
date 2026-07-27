require "test_helper"

# [component] The gem-only deployment surface on tasks/_release_summary
# (gem-only-deployments): a gem_only? release wears a GEM-ONLY badge and shows the
# published gem (💎 <gem> <version>) as its artifact INSTEAD of the Prod ↗ link +
# deployed SHA — because a gem publish IS its production deployment. A normal app
# release renders byte-for-byte as before (Prod link + SHA, no GEM-ONLY badge),
# which is the regression guard that the branch is scoped to gem-only releases.
class ReleaseSummaryGemOnlyTest < ActionView::TestCase
  test "[component] a gem-only release shows the GEM-ONLY badge + 💎 gem artifact, not Prod/SHA" do
    rel = Release.open!(branch: "release/gem-only-badge")
    # A studio-engine member makes gem_release? true → gem_only? true.
    add_member(rel, "studio-engine", position: 10)
    # Even WITH a production_url + deployed_sha set, the gem-only branch must show
    # the gem artifact instead — the release deployed a GEM, not an app.
    rel.update!(production_url: "https://mcritchie.studio", deployed_sha: "deadbeef1234567")

    render partial: "tasks/release_summary", locals: { release: rel.reload, variant: :last }

    assert_select "[data-test='release-gem-only-badge']", 1, "a gem-only release wears the GEM-ONLY badge"
    assert_select "[data-test='release-gem-only-badge']", text: /Gem-only/
    assert_select "[data-test='release-gem-artifact']", 1, "it shows the published gem as its artifact"
    assert_select "[data-test='release-gem-artifact']", text: /studio-engine/
    # The 💎 rides the shared app_emoji_badge (studio-engine → 💎).
    assert_includes rendered, "💎"
    # The app artifact branch is REPLACED — no Prod link, no deployed SHA.
    assert_select "a", text: "Prod ↗", count: 0
    assert_select "code[title='deployed SHA']", count: 0
  end

  test "[component] a normal app release renders unchanged — Prod ↗ + SHA, no GEM-ONLY badge" do
    rel = Release.open!(branch: "release/app-regression")
    add_member(rel, "mcritchie-studio", position: 10)
    rel.update!(production_url: "https://mcritchie.studio", deployed_sha: "cafebabe7654321")

    render partial: "tasks/release_summary", locals: { release: rel.reload, variant: :last }

    assert_select "[data-test='release-gem-only-badge']", 0, "an app release is NOT gem-only"
    assert_select "[data-test='release-gem-artifact']", 0, "and shows no gem artifact"
    assert_select "a", text: "Prod ↗", count: 1
    assert_select "code[title='deployed SHA']", text: /cafebab/
  end

  test "[component] a mixed gem+app release is NOT gem-only (keeps the app artifact)" do
    rel = Release.open!(branch: "release/mixed")
    add_member(rel, "studio-engine", position: 10)
    add_member(rel, "mcritchie-studio", position: 20)
    rel.update!(production_url: "https://mcritchie.studio", deployed_sha: "abc1234def5678")

    render partial: "tasks/release_summary", locals: { release: rel.reload, variant: :last }

    assert_not rel.reload.gem_only?, "a gem RIDING an app is not a gem-only release"
    assert_select "[data-test='release-gem-only-badge']", 0
    assert_select "a", text: "Prod ↗", count: 1
  end

  private

  def add_member(rel, repo, position:)
    Task.create!(title: "member #{repo} #{SecureRandom.hex(2)}", stage: "reviewed", position: position,
                 release_slug: rel.slug, metadata: { "devops" => { "repositories" => [repo] } })
  end
end
