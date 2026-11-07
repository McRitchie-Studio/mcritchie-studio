# The tiles of the logo grid backdrop (app/views/shared/_logo_grid.html.erb,
# app/javascript/logo_grid.js; task logo-grid-backdrop): the agents' faces and
# the apps' logos, each a 160px square in app/assets/images/logo_grid/.
#
# The Pokémon soul's face is official Pokémon art, so it stays off this public
# grid. The Turf Monster soul wears the app's own crocodile, so the app tile
# stands for both.
module LogoGridHelper
  LOGO_GRID_TILES = [
    %w[agent-alex Alex],
    %w[app-mcritchie-studio McRitchie\ Studio],
    %w[agent-carl Carl],
    %w[app-turf-monster Turf\ Monster],
    %w[agent-avi Avi],
    %w[agent-shannon Shannon],
    %w[app-cyvasse Cyvasse],
    %w[agent-mason Mason],
    %w[agent-jasper Jasper],
    %w[app-10and5 10&5],
    %w[agent-steffon Steffon],
    %w[agent-mack Mack],
    %w[agent-hank Hank]
  ].freeze

  def logo_grid_tiles
    LOGO_GRID_TILES.map { |file, label| { src: image_path("logo_grid/#{file}.webp"), label: } }
  end
end
