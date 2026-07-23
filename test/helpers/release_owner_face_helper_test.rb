require "test_helper"

# [unit] The Next Release card's conductor-owner face. ApplicationHelper#
# release_role_owner_face resolves a release ROLE's ReleaseConductorClaim → its
# holder SESSION → that session's SessionMascot Pokémon, and renders the face — or
# NOTHING when the role has no claim / no holder yet. This helper is the ONE source
# both the /deployments page render and the DeploymentsBroadcaster live morph read,
# so its mapping (and its "render nothing" contract) are pinned here.
class ReleaseOwnerFaceHelperTest < ActionView::TestCase
  include ApplicationHelper

  setup do
    Pokemon.create!(dex: 25, name: "Pikachu", slug: "pikachu", types: %w[electric],
                    generation: 1, sprite_url: "https://img.test/pikachu.png")
    Pokemon.create!(dex: 95, name: "Onix", slug: "onix", types: %w[rock ground],
                    generation: 1, sprite_url: "https://img.test/onix.png")
  end

  test "[unit] maps the assembler + deployer claim sessions to their Pokémon faces" do
    release = Release.create!(slug: "rel-faces", branch: "release", state: "assembling")

    claim_role("rel-faces", "assembler", session: "sess-qa")
    claim_role("rel-faces", "deployer", session: "sess-deploy")
    SessionMascot.create!(session_id: "sess-qa", mascot_slug: "pikachu")
    SessionMascot.create!(session_id: "sess-deploy", mascot_slug: "onix")

    assembler = release_role_owner_face(release, "assembler")
    deployer  = release_role_owner_face(release, "deployer")

    assert_includes assembler, 'data-pokemon="pikachu"'
    assert_includes assembler, "QA (assembler): Pikachu"
    assert_includes assembler, "https://img.test/pikachu.png"

    assert_includes deployer, 'data-pokemon="onix"'
    assert_includes deployer, "Deploy (deployer): Onix"
    assert_includes deployer, "https://img.test/onix.png"
  end

  test "[unit] renders nothing for a role with no claim, or once the claim is released" do
    release = Release.create!(slug: "rel-empty", branch: "release", state: "assembling")

    # No claim row at all for this role -> nothing.
    assert_nil release_role_owner_face(release, "assembler")

    # A live claim with a holder + mascot -> a face...
    claim_role("rel-empty", "deployer", session: "sess-x")
    SessionMascot.create!(session_id: "sess-x", mascot_slug: "onix")
    assert_includes release_role_owner_face(release, "deployer"), 'data-pokemon="onix"'

    # ...but once released the row survives with no holder session, so no face.
    ReleaseConductorClaim.release(release_slug: "rel-empty", role: "deployer",
                                  session: "sess-x", nonce: "n-sess-x")
    assert_nil release_role_owner_face(release, "deployer"),
               "a released claim has no holder session, so it renders nothing"
  end

  test "[unit] a holder session with no SessionMascot row renders nothing (strict read, no mint)" do
    release = Release.create!(slug: "rel-nomascot", branch: "release", state: "assembling")
    claim_role("rel-nomascot", "assembler", session: "sess-none")
    # The holder session never drew a mascot — there is NO SessionMascot row for it.
    # The helper reads with find_by (never .for), so it must resolve to nil WITHOUT
    # minting one: a write-on-read on a GET/morph is the bug this pins.
    assert_nil SessionMascot.find_by(session_id: "sess-none"), "precondition: no row yet"

    assert_nil release_role_owner_face(release, "assembler")

    assert_nil SessionMascot.find_by(session_id: "sess-none"),
               "rendering the face must NOT create a SessionMascot as a side effect"
  end

  private

  def claim_role(slug, role, session:)
    ReleaseConductorClaim.acquire(release_slug: slug, role: role,
                                  session: session, nonce: "n-#{session}")
  end
end
