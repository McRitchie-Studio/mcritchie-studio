# The tiles of the logo grid backdrop (app/views/shared/_logo_grid.html.erb,
# app/javascript/logo_grid.js; task logo-grid-backdrop): the agents' faces and
# the apps' logos, each a 160px square in app/assets/images/logo_grid/. The
# apps are the portfolio (config/apps.yml status: showcase) plus the Studio and
# alex.build; each tile is made from that app's own public/icon.png.
#
# The Pokémon soul's face is official Pokémon art, so it stays off this public
# grid. The Turf Monster soul wears the app's own crocodile, so the app tile
# stands for both.
module LogoGridHelper
  LOGO_GRID_TILES = [
    %w[app-turf-monster Turf\ Monster],
    %w[agent-alex Alex],
    %w[app-rantly Rantly],
    %w[agent-carl Carl],
    %w[app-cyvasse Cyvasse],
    %w[app-search-position Search\ Position],
    %w[agent-avi Avi],
    %w[app-weekly-lock Weekly\ Lock],
    %w[agent-shannon Shannon],
    %w[app-prisoners-dilemma Prisoner's\ Dilemma],
    %w[app-mcritchie-studio McRitchie\ Studio],
    %w[agent-mason Mason],
    %w[app-10and5 10&5],
    %w[agent-jasper Jasper],
    %w[app-portfolio Portfolio],
    %w[agent-steffon Steffon],
    %w[app-alex-build alex.build],
    %w[agent-mack Mack],
    %w[app-dads-app Dads\ App],
    %w[agent-hank Hank]
  ].freeze

  def logo_grid_tiles
    LOGO_GRID_TILES.map { |file, label| { src: image_path("logo_grid/#{file}.webp"), label: } }
  end
end
