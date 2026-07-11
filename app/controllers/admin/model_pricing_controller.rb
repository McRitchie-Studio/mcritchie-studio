module Admin
  # Admin Model Pricing — the roster table (index), a per-model detail page with
  # the rate sliders + last-session cost (show), and the override save (update).
  # Admin-gated; a saved override flows into UsagePricing for future costing.
  class ModelPricingController < ApplicationController
    before_action :require_admin
    before_action :set_model, only: %i[show update]

    def index
      @rows = ModelPricing.roster
    end

    def show
      @row = ModelPricing.for_model(@model)
      @override ||= ModelRateOverride.find_or_initialize_by(model: @model)
      @session_activities = ModelPricing.session_activities(@model, @row.session_id)
      # Slider start values: the saved override if present, else the model's
      # current (roster/env) rate.
      @input_rate  = (@override.input_rate  || @row.input_rate).to_f
      @output_rate = (@override.output_rate || @row.output_rate).to_f
    end

    def update
      @override = ModelRateOverride.find_or_initialize_by(model: @model)
      rescue_and_log(target: @override) do
        @override.update!(rate_params)
        redirect_to admin_model_pricing_model_path(@model), notice: "Rates updated for #{@model}."
      end
    rescue StandardError
      show
      render :show, status: :unprocessable_entity
    end

    private

    # Only price roster models — an unknown id (or a probe) 404s rather than
    # letting anyone persist a rate for a model we don't recognize.
    def set_model
      @model = params[:model].to_s
      head :not_found unless UsagePricing::RATES.key?(@model)
    end

    def rate_params
      params.require(:model_rate_override).permit(:input_rate, :output_rate)
    end
  end
end
