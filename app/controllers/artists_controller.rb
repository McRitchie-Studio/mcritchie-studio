# frozen_string_literal: true

# GET /artists/search.json?q= — the cast panel's typeahead (Artists::Search).
class ArtistsController < ApplicationController
  # JSON, so a refusal is a status the typeahead can read, not a redirect to HTML.
  before_action { head :forbidden unless admin? }

  def search
    results = Artists::Search.call(params[:q])
    render json: results.map { |r| r.to_h.except(:rank) }
  end
end
