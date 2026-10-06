require "test_helper"

# [integration] GET /stack — admin-only, and each client's software strip is
# read from its tier and the credential census together.
class StackControllerTest < ActionDispatch::IntegrationTest
  setup do
    vault = CredentialVault.create!(slug: "studio-agents", name: "Studio agents", entity: "studio", lane: "agents")
    CredentialRecord.create!(credential_vault: vault, title: "turf.stripe", service: "stripe", entity: "turf-monster")
    StackClient.create!(slug: "turf-monster", name: "Turf Monster", tier: "pro")
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
    assert_select "[data-client='turf-monster'] [data-test='stack-tier']", text: /Pro/
    assert_select "[data-client='turf-monster'] [data-software='heroku'][data-hosting='ms']", 1, "Pro tier provisions Heroku"
    assert_select "[data-client='turf-monster'] [data-software='stripe'][data-hosting='own']", 1, "the record brings Stripe"
    assert_select "[data-client='turf-monster'] [data-software='google']", 0, "Pro does not include Google"
  end

  test "[integration] each client shows its app tier and status from config/apps.yml" do
    StackClient.create!(slug: "family", name: "McRitchie Family", tier: StackClient::INTERNAL, position: 95)
    log_in_as users(:alex)
    get stack_path

    assert_response :success
    turf = AppCatalog.app("turf-monster")
    assert_select "[data-client='turf-monster'] [data-test='stack-app'][data-app='turf-monster']" \
                  "[data-app-tier='#{turf.tier}'][data-app-status='#{turf.status}']", 1
    assert_select "[data-client='turf-monster'] [data-test='stack-app']", text: /Product\s+Showcase/
    assert_select "[data-client='family'] [data-test='stack-app'][data-app='']", { text: "—", count: 1 },
                  "a client with no app record draws a dash"
  end

  test "[integration] the matrix summary band leads with the app tier and status" do
    StackClient.create!(slug: "studio", name: "McRitchie Studio", tier: StackClient::INTERNAL, position: 90)
    log_in_as users(:alex)
    get stack_matrix_path

    assert_response :success
    assert_equal "app", css_select("[data-test='matrix-summary-row']").first["data-field"]
    assert_select "[data-field='app'] [data-client='studio'] [data-test='stack-app'][data-app-tier='studio'][data-app-status='active']", 1
    assert_select "[data-field='app'] [data-client='turf-monster'] [data-test='stack-app']", text: /Product\s+Showcase/
  end

  # [component] GET /stack/matrix — the same clients as columns, software rows
  # by category, each cell ms (Studio chest), own (check) or none (dash).
  test "a visitor who is not signed in is sent to log in from the matrix" do
    get stack_matrix_path

    assert_redirected_to "/login"
  end

  test "a signed-in non-admin is refused the matrix" do
    log_in_as users(:viewer)
    get stack_matrix_path

    assert_redirected_to root_path
  end

  test "the matrix draws clients as columns and each cell from the derived stack" do
    StackClient.create!(slug: "studio", name: "McRitchie Studio", tier: StackClient::INTERNAL, position: 90,
                        domain: "mcritchie.studio", resend_mode: "ms", extra_software: %w[anthropic slack],
                        hosting: { "slack" => "own" })
    log_in_as users(:alex)
    get stack_matrix_path

    assert_response :success
    assert_select "[data-test='matrix-client']", 2
    assert_equal %w[turf-monster studio], css_select("[data-test='matrix-client']").map { |th| th["data-client"] },
                 "columns follow StackClient.ordered"
    assert_select "[data-test='stack-list-link'][href='#{stack_path}']"

    cell = ->(software, client) { "[data-software='#{software}'] [data-test='matrix-cell'][data-client='#{client}']" }
    assert_select "#{cell.('heroku', 'turf-monster')}[data-state='ms'] img", 1, "the tier's Heroku runs on our account: the chest"
    assert_select "#{cell.('stripe', 'turf-monster')}[data-state='own']", text: "✓", count: 1
    assert_select "#{cell.('anthropic', 'studio')}[data-state='ms']", 1
    assert_select "#{cell.('slack', 'studio')}[data-state='own']", 1, "the hosting override draws it as their own"
    assert_select "#{cell.('anthropic', 'turf-monster')}[data-state='none']", text: "—", count: 1
    assert_select "[data-test='matrix-category'][data-category='ai'] [data-software='anthropic']", 1
    assert_select "[data-test='matrix-software'][data-software='x']", 0, "no client runs X, so it has no row"

    assert_select "[data-field='price'] [data-client='studio']", text: "Internal"
    assert_select "[data-field='domain'] [data-client='studio']", text: "mcritchie.studio"
    assert_select "[data-field='resend'] [data-client='studio']", text: "McRitchie Studio"
    assert_select "[data-field='hosting'] [data-client='turf-monster']", text: "MS-hosted"
  end

  test "the matrix totals MRR over priced clients only" do
    paid = WorkspacePackage.all.select { |package| package.priced? && !package.free? }
    StackClient.find_by!(slug: "turf-monster").update!(tier: paid.last.key)
    StackClient.create!(slug: "commercial-welding", name: "Commercial Welding", tier: paid.first.key)
    StackClient.create!(slug: "studio", name: "McRitchie Studio", tier: StackClient::INTERNAL)
    log_in_as users(:alex)
    get stack_matrix_path

    total = paid.last.price_monthly + paid.first.price_monthly
    assert_select "[data-test='matrix-mrr-value']", text: ActiveSupport::NumberHelper.number_to_currency(total, precision: 0)
    assert_select "[data-test='matrix-paying-count']", text: "2"
  end

  test "the list view links to the matrix" do
    log_in_as users(:alex)
    get stack_path

    assert_select "[data-test='stack-matrix-link'][href='#{stack_matrix_path}']"
  end
end
