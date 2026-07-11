# frozen_string_literal: true

require "test_helper"

# [integration] Admin Model Pricing — admin gating, the roster table, the detail
# sliders, roster validation, and the save→persist→re-price round trip.
class Admin::ModelPricingControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin  = users(:alex)
    @viewer = users(:viewer)
  end

  test "index sends an anonymous visitor to login" do
    get admin_model_pricing_path
    assert_redirected_to "/login"
  end

  test "index sends a logged-in non-admin home" do
    log_in_as(@viewer)
    get admin_model_pricing_path
    assert_redirected_to root_path
  end

  test "admin sees the roster table with model links" do
    log_in_as(@admin)
    get admin_model_pricing_path
    assert_response :success
    assert_select "h1", text: /Model Pricing/
    assert_select "td a", text: "opus-4-8"
    assert_select "td a", text: "haiku-4-5"
  end

  test "detail page renders the input and output rate sliders" do
    log_in_as(@admin)
    get admin_model_pricing_model_path("claude-opus-4-8")
    assert_response :success
    assert_select "input[type=range][name=?]", "model_rate_override[input_rate]"
    assert_select "input[type=range][name=?]", "model_rate_override[output_rate]"
  end

  test "detail page 404s for a model outside the roster" do
    log_in_as(@admin)
    get admin_model_pricing_model_path("totally-unknown-model")
    assert_response :not_found
  end

  test "admin update persists an override and it flows into UsagePricing" do
    log_in_as(@admin)
    assert_equal BigDecimal("5.0"), UsagePricing.price({ "input" => 1_000_000 }, "claude-opus-4-8")

    patch admin_model_pricing_model_path("claude-opus-4-8"),
          params: { model_rate_override: { input_rate: "7.5", output_rate: "25" } }

    assert_redirected_to admin_model_pricing_model_path("claude-opus-4-8")
    override = ModelRateOverride.find_by(model: "claude-opus-4-8")
    assert_equal 7.5, override.input_rate.to_f
    assert_equal BigDecimal("7.5"), UsagePricing.price({ "input" => 1_000_000 }, "claude-opus-4-8")
  end

  test "a failed rate write logs an ErrorLog carrying the override breadcrumb" do
    log_in_as(@admin)
    assert_difference "ErrorLog.count", 1 do
      patch admin_model_pricing_model_path("claude-opus-4-8"),
            params: { model_rate_override: { input_rate: "-5", output_rate: "25" } }
    end
    assert_response :unprocessable_entity
    assert_equal "claude-opus-4-8", ErrorLog.order(:created_at).last.target_name
    assert_nil ModelRateOverride.find_by(model: "claude-opus-4-8")
  end

  test "a non-admin update is blocked and persists nothing" do
    log_in_as(@viewer)
    patch admin_model_pricing_model_path("claude-opus-4-8"),
          params: { model_rate_override: { input_rate: "7.5", output_rate: "25" } }
    assert_redirected_to root_path
    assert_nil ModelRateOverride.find_by(model: "claude-opus-4-8")
  end
end
