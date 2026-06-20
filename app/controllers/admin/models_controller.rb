module Admin
  class ModelsController < ApplicationController
    before_action :require_admin

    include Studio::AdminModels

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
      },
      "coaches" => {
        label: "Coaches",
        description: "Coach assignments by person, team, role, and sport"
      }
    }.freeze

    private

    def admin_model_scope_for(key)
      case key
      when "users"
        User.with_attached_avatar.order(created_at: :desc)
      when "teams"
        Team.includes(:home_arena).order(team_sort_order)
      when "arenas"
        Arena.includes(:home_teams).order(:name)
      when "coaches"
        Coach.ordered_for_admin
      else
        raise ActiveRecord::RecordNotFound
      end
    end
  end
end
