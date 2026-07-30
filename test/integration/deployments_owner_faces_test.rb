require "test_helper"

# [integration] Two /deployments changes shipped together:
#   A) the Next Release card shows the QA (assembler) + deploy (deployer)
#      conductor-owner Pokémon faces, resolved from the release's
#      ReleaseConductorClaim rows via the holder sessions' mascots; a role with no
#      claim renders no face, and the row hides when both are absent.
#   B) the standalone GitHub Actions panel is GONE — the per-repo CI progress bars
#      carry the CI signal now, so no #github-actions-panel renders at all.
class DeploymentsOwnerFacesTest < ActionDispatch::IntegrationTest
  setup do
    Release.delete_all
    ReleaseConductorClaim.delete_all
    SessionMascot.delete_all
    Pokemon.create!(dex: 25, name: "Pikachu", slug: "pikachu", types: %w[electric],
                    generation: 1, sprite_url: "https://img.test/pikachu.png")
    Pokemon.create!(dex: 95, name: "Onix", slug: "onix", types: %w[rock ground],
                    generation: 1, sprite_url: "https://img.test/onix.png")
  end

  test "[integration] Next Release card renders the assembler + deployer owner faces" do
    release = Release.open!(branch: "release/owner-faces")
    ReleaseConductorClaim.acquire(release_slug: release.slug, role: "assembler",
                                  session: "sess-qa", nonce: "n1")
    ReleaseConductorClaim.acquire(release_slug: release.slug, role: "deployer",
                                  session: "sess-deploy", nonce: "n2")
    SessionMascot.create!(session_id: "sess-qa", mascot_slug: "pikachu")
    SessionMascot.create!(session_id: "sess-deploy", mascot_slug: "onix")

    get deployments_path
    assert_response :success

    assert_select "#current-release [data-test='release-owner-faces']", 1
    assert_select "#current-release [data-test='release-owner-face'][data-role='assembler'][data-pokemon='pikachu']", 1
    assert_select "#current-release [data-test='release-owner-face'][data-role='deployer'][data-pokemon='onix']", 1
    assert_select "#current-release [data-test='release-owner-face'][data-role='assembler'] img[src='https://img.test/pikachu.png']"
    assert_select "#current-release [data-test='release-owner-face'][title=?]", "QA (assembler): Pikachu"
    assert_select "#current-release [data-test='release-owner-face'][title=?]", "Deploy (deployer): Onix"

    # Placement: the faces sit in the top-right badge cluster alongside the status
    # badge (moved up from below the tracker), so the operator sees who is driving
    # the deploy right next to the "Assembling" pill.
    assert_select "[data-test='release-badge-cluster'] [data-test='release-owner-faces']", 1
    assert_select "[data-test='release-badge-cluster'] [data-test='release-state-badge']", 1
    assert_select "[data-test='release-badge-cluster'] [data-test='release-owner-face']", 2

    # Size: the avatars render a touch larger than the 24px conductor-mascot row.
    assert_select "#current-release [data-test='release-owner-face'] img.w-7.h-7", 2
  end

  test "[integration] a role with no claim renders no face, and the row hides when both absent" do
    Release.open!(branch: "release/no-claims")

    get deployments_path
    assert_response :success

    assert_select "[data-test='release-owner-faces']", 0
    assert_select "[data-test='release-owner-face']", 0
  end

  test "[integration] the GitHub Actions panel is gone from /deployments" do
    Release.open!(branch: "release/panel-gone")
    # Even with an ingested workflow run present, the panel no longer renders.
    GithubWorkflowRun.create!(repo: "McRitchie-Studio/mcritchie-studio", workflow_name: "CI",
                              run_id: 9001, status: "in_progress",
                              head_sha: "a" * 40, head_branch: "release",
                              html_url: "https://github.com/x/actions/runs/9001",
                              run_started_at: Time.current)

    get deployments_path
    assert_response :success

    assert_select "#github-actions-panel", 0
    assert_select "[data-test='github-actions-panel']", 0
    assert_select "[data-test='github-actions-run']", 0
  end
end
