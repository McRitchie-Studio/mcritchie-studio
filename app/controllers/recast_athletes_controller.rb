# frozen_string_literal: true

# GET /recast_athletes/search.json?q= — the recast picker's typeahead: People
# with looks, each with the looks to choose from (MusicVideos::RecastAthleteSearch).
class RecastAthletesController < ApplicationController
  # JSON, so a refusal is a status the typeahead can read, not a redirect to HTML.
  before_action { head :forbidden unless admin? }

  def search
    render json: MusicVideos::RecastAthleteSearch.call(params[:q]).map(&:to_h)
  end
end
