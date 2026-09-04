# frozen_string_literal: true

require "test_helper"

# [integration] The admin signing console is GONE — its routes, its route
# helpers, its tables, and the admin surfaces that advertised it.
#
# Mr. McRitchie, 2026-09-04: Turf Monster is the hub for ALL Solana/web3 logic,
# so the hub keeps none (/tasks/retire-signing-console). The console had been ON
# ICE since 2026-08-31 and was the hub's last real consumer of solana-studio, so
# removing it is what let the Gemfile line and the Web2AppBoundary exemption go
# with it — that half is owned by test/lib/web2_app_boundary_test.rb.
#
# Asserted on the ROUTE SET and the SCHEMA, never on a page's text alone: a view
# can stop LINKING to a console that is still served, and that is not a removal.
class SigningConsoleRetiredTest < ActionDispatch::IntegrationTest
  CONSOLE_ROUTES = {
    "/admin/signing_requests"     => :get,
    "/admin/signing_requests/new" => :get
  }.freeze

  test "no signing console route is drawn" do
    CONSOLE_ROUTES.each do |path, verb|
      assert_raises ActionController::RoutingError, "#{verb.upcase} #{path} must not route" do
        Rails.application.routes.recognize_path(path, method: verb)
      end
    end
  end

  # The biting half of the pair: a re-drawn route restores these helpers, and a
  # view or test calling one would raise NoMethodError today.
  test "the signing console route helpers are undefined" do
    helpers = Rails.application.routes.url_helpers
    %i[admin_signing_requests_path new_admin_signing_request_path].each do |helper|
      refute helpers.respond_to?(helper),
             "#{helper} must be gone — a view or test calling it would raise NoMethodError"
    end
  end

  # Dropped, not merely orphaned. Measured against production before the drop:
  # SigningRequest.count => 0, DurableNonce => one devnet row.
  test "the console tables are gone from the schema" do
    tables = ActiveRecord::Base.connection.tables

    refute_includes tables, "signing_requests"
    refute_includes tables, "durable_nonces"
  end

  # An admin session is the only one that could ever see the link, so it is the
  # one that has to come back without it.
  test "the admin hub and dashboard no longer advertise the console" do
    log_in_as(users(:alex))

    get admin_links_path
    assert_response :success
    assert_no_match "Signing Console", response.body

    get admin_dashboard_path
    assert_response :success
    assert_no_match "Signing Console", response.body
  end
end
