require "test_helper"

# [integration] GET /stack — admin-only, and each client's software strip is
# read from its tier and the credential census together.
class StackControllerTest < ActionDispatch::IntegrationTest
  setup do
    vault = CredentialVault.create!(slug: "studio-agents", name: "Studio agents", entity: "studio", lane: "agents")
    CredentialRecord.create!(credential_vault: vault, title: "turf.stripe", service: "stripe", entity: "turf-monster")
    StackClient.create!(slug: "turf-monster", name: "Turf Monster", tier: "host")
  end

  test "a visitor who is not signed in is sent to log in" do
    get stack_path

    assert_redirected_to "/login"
  end

  test "a signed-in non-admin is refused" do
    log_in_as users(:viewer)
    get stack_path

    assert_redirected_to root_path
  end

  test "an admin sees each client with its tier software and its records' software" do
    log_in_as users(:alex)
    get stack_path

    assert_response :success
    assert_select "[data-client='turf-monster'] [data-test='stack-tier']", text: /Host/
    assert_select "[data-client='turf-monster'] [data-software='heroku'][data-hosting='ms']", 1, "Host tier provisions Heroku"
    assert_select "[data-client='turf-monster'] [data-software='stripe'][data-hosting='own']", 1, "the record brings Stripe"
    assert_select "[data-client='turf-monster'] [data-software='google']", 0, "Host does not include Google"
  end
end
