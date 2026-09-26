require "test_helper"

# [integration] GET /credentials — admin-only, and the matrix it serves is read
# from the records and the icon config together.
class CredentialVaultsControllerTest < ActionDispatch::IntegrationTest
  setup do
    vault = CredentialVault.create!(slug: "studio-agents", name: "Studio agents", entity: "studio", lane: "agents")
    CredentialRecord.create!(credential_vault: vault, title: "heroku.studio.agents", service: "heroku")
    CredentialRecord.create!(credential_vault: vault, title: "turf.stripe", service: "stripe", entity: "turf-monster")
  end

  test "a visitor who is not signed in is sent to log in" do
    get credentials_path

    assert_redirected_to "/login"
  end

  test "a signed-in non-admin is refused" do
    log_in_as users(:viewer)
    get credentials_path

    assert_redirected_to root_path
  end

  test "an admin sees the matrix, each record under the client it serves" do
    log_in_as users(:alex)
    get credentials_path

    assert_response :success
    assert_select "[data-test='credential-matrix']"
    assert_select "[data-service='heroku'] [data-test='matrix-cell'][data-entity='studio'] [data-test='matrix-icon']", 1
    assert_select "[data-service='stripe'] [data-test='matrix-cell'][data-entity='turf-monster'] [data-test='matrix-icon']", 1
    assert_select "[data-service='stripe'] [data-test='matrix-cell'][data-entity='studio'] [data-test='matrix-icon']", 0
  end
end
