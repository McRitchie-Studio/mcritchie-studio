# /devops/sessions — the session roster (SessionRoster): every agent session of
# the last 60 days with its Pokémon, tasks and whether it ran /wrap, so the
# unwrapped ones can be chased down. Admin-only and read-only, like the board.
# The ending filter is a plain ?ending= link, so it works without JavaScript.
class SessionRosterController < ApplicationController
  def index
    @roster = SessionRoster.new
    @ending = SessionRoster::ENDINGS.include?(params[:ending]) ? params[:ending] : "all"
    @background = params[:background] == "1"
    @rows = @roster.filtered(ending: @ending, background: @background)
    @counts = @roster.counts
    @pokemon = Pokemon.where(slug: @rows.map(&:mascot_slug).compact.uniq).index_by(&:slug)
  end
end
