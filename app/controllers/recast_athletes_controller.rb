# frozen_string_literal: true

# GET /recast_athletes/search.json?q= — the recast picker's typeahead: every
# Person by name or alias, each with the looks to choose from; a person with no
# look is listed too, with none (MusicVideos::RecastAthleteSearch).
class RecastAthletesController < ApplicationController
  # JSON, so a refusal is a status the typeahead can read, not a redirect to HTML.
  before_action { head :forbidden unless admin? }

  def search
    render json: MusicVideos::RecastAthleteSearch.call(params[:q]).map(&:to_h)
  end
end
