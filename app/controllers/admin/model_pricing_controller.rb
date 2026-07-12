module Admin
  # Admin Model Pricing — the roster table (index), a per-model detail page with
  # the rate sliders + last-session cost (show), and the override save (update).
  # Admin-gated; a saved override flows into UsagePricing for future costing.
  class ModelPricingController < ApplicationController
    # The same read layer /agents/activities uses, so this page renders the session's
    # activities through the REAL feed row partial instead of a bespoke table — one
    # bulk query per lookup, no N+1, and the two surfaces can never drift apart.
    include ActivityFeed

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
      # The model's ABSOLUTE cache-write rate, when it has one (gpt-5.5-style). nil means
      # the write tier derives from the input rate, so the live calculator must re-derive
      # it as the input slider moves — exactly as UsagePricing.price does server-side.
      @absolute_write_rate = (UsagePricing.rate_for(@model) || {})[:cache_creation]
      load_activity_feed
    end

    def update
      @override = ModelRateOverride.find_or_initialize_by(model: @model)
      # Only the WRITE is wrapped: a redirect inside the block would make a
      # double-render surface as a *pricing* failure in ErrorLog.
      rescue_and_log(target: @override) { @override.update!(rate_params) }
      redirect_to admin_model_pricing_model_path(@model), notice: "Rates updated for #{@model}."
    rescue StandardError
      show
      render :show, status: :unprocessable_entity
    end

    private

    # Locals for agents/_activities_table — the bulk lookups from ActivityFeed, each
    # ONE query, exactly as the feed page builds them.
    def load_activity_feed
      activities = @session_activities.includes(:agent_actions).to_a
      @activity_rows = activities.map do |activity|
        [activity, activity.agent_actions.sort_by { |a| [a.occurred_at, a.seq, a.id] }.reverse]
      end
      actions = @activity_rows.flat_map(&:last)

      @pokemon_by_slug   = pokemon_lookup(actions, activities)
      @agents_by_slug    = agent_soul_lookup(activities)
      @activity_grades   = activity_grade_lookup(activities)
      @action_grades     = action_grade_lookup(actions)
      @shared_turn_ids   = feed_shared_turn_ids(actions)
      @stage_transitions = stage_transitions_for(activities)
    end

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
