module Admin
  class ModelsController < ApplicationController
    PREVIEW_LIMIT = 10
    PER_PAGE = 25

    MODELS = {
      "users" => {
        label: "Users",
        description: "Accounts and authentication state"
      },
      "teams" => {
        label: "Teams",
        description: "Sports teams and home arena links"
      },
      "arenas" => {
        label: "Arenas",
        description: "Venues seeded for schedules and teams"
      }
    }.freeze

    before_action :require_admin
    before_action :set_model_config, only: :show

    def index
      @sections = MODELS.map do |key, config|
        {
          key: key,
          label: config.fetch(:label),
          description: config.fetch(:description),
          count: scope_for(key).count,
          records: scope_for(key).limit(PREVIEW_LIMIT)
        }
      end
    end

    def show
      @page = [params[:page].to_i, 1].max
      @total_count = @scope.count
      @total_pages = [(@total_count.to_f / PER_PAGE).ceil, 1].max
      @records = @scope.offset((@page - 1) * PER_PAGE).limit(PER_PAGE)
    end

    private

    def set_model_config
      @key = params[:key].to_s
      @config = MODELS.fetch(@key) { raise ActiveRecord::RecordNotFound }
      @scope = scope_for(@key)
    end

    def scope_for(key)
      case key
      when "users"
        User.with_attached_avatar.order(created_at: :desc)
      when "teams"
        Team.includes(:home_arena).order(:league, :name)
      when "arenas"
        Arena.includes(:home_teams).order(:name)
      else
        raise ActiveRecord::RecordNotFound
      end
    end
  end
end
