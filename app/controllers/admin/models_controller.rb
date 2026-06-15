module Admin
  class ModelsController < ApplicationController
    PREVIEW_LIMIT = 10
    PER_PAGE = 25
    TEAM_SORTS = {
      "team" => "LOWER(teams.name)",
      "sport" => "LOWER(COALESCE(teams.sport, ''))",
      "league" => "LOWER(COALESCE(teams.league, ''))"
    }.freeze

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
    helper_method :team_sort_url, :team_sort_indicator, :team_sport_emoji, :team_record_json

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
        Team.includes(:home_arena).order(team_sort_order)
      when "arenas"
        Arena.includes(:home_teams).order(:name)
      else
        raise ActiveRecord::RecordNotFound
      end
    end

    def team_sort_key
      TEAM_SORTS.key?(params[:sort].to_s) ? params[:sort].to_s : "team"
    end

    def team_sort_direction
      params[:direction].to_s == "desc" ? "desc" : "asc"
    end

    def team_sort_order
      direction = team_sort_direction == "desc" ? "DESC" : "ASC"
      expression = TEAM_SORTS.fetch(team_sort_key)
      Arel.sql("#{expression} #{direction}, LOWER(teams.name) ASC")
    end

    def team_sort_url(key)
      query = request.query_parameters.merge(
        "sort" => key,
        "direction" => team_sort_key == key && team_sort_direction == "asc" ? "desc" : "asc"
      )
      query.delete("page")

      "#{request.path}?#{query.to_query}"
    end

    def team_sort_indicator(key)
      return "" unless team_sort_key == key

      team_sort_direction
    end

    def team_sport_emoji(team)
      case team.sport.to_s
      when "football" then "🏈"
      when "soccer" then "⚽"
      when "basketball" then "🏀"
      when "baseball" then "⚾"
      when "hockey" then "🏒"
      else "•"
      end
    end

    def team_record_json(team)
      JSON.pretty_generate(
        team.attributes.merge(
          "home_arena" => team.home_arena&.attributes
        )
      )
    end
  end
end
