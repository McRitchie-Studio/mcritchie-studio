class ContractsController < ApplicationController
  # GET /nfl-contracts
  def index
    @sort_by = params[:sort].presence || "salary"

    query = Contract
      .joins(:person, :team)
      .where(teams: { league: "nfl" })
      .select(
        "contracts.*",
        "people.first_name", "people.last_name",
        "teams.name AS team_name", "teams.short_name AS team_short_name",
        "teams.emoji AS team_emoji"
      )

    if params[:search].present?
      term = "%#{params[:search].downcase}%"
      query = query.where(
        "LOWER(people.first_name) LIKE ? OR LOWER(people.last_name) LIKE ? OR LOWER(teams.name) LIKE ?",
        term, term, term
      )
    end

    if params[:type].present? && Contract::CONTRACT_TYPES.include?(params[:type])
      query = query.where(contract_type: params[:type])
    end

    query = case @sort_by
            when "name" then query.order(Arel.sql("people.last_name ASC, people.first_name ASC"))
            when "team" then query.order(Arel.sql("teams.name ASC, people.last_name ASC"))
            when "position" then query.order(Arel.sql("contracts.position ASC NULLS LAST, contracts.annual_value_cents DESC NULLS LAST"))
            else query.order(Arel.sql("contracts.annual_value_cents DESC NULLS LAST, people.last_name ASC"))
            end

    @contracts = query.to_a
  end
end
