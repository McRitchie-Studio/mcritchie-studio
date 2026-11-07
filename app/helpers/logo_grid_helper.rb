# The tiles of the logo grid backdrop (app/views/shared/_logo_grid.html.erb,
# app/javascript/logo_grid.js; task logo-grid-backdrop): the agents' faces and
# the apps' logos, each a 160px square in app/assets/images/logo_grid/, made
# from each app's own icon. Alex McRitchie picks the apps (2026-11-07): the
# showcase rebuilds with generic icons (Search Position, Portfolio, Rantly,
# Prisoner's Dilemma, Weekly Lock) are not portfolio apps and stay off;
# McRitchie Industries, Commercial Welding and Voicebox are in (same day).
#
# The Pokémon soul's face is official Pokémon art, so it stays off this public
# grid. The Turf Monster soul wears the app's own crocodile, so the app tile
# stands for both.
module LogoGridHelper
  LOGO_GRID_TILES = [
    %w[app-turf-monster Turf\ Monster],
    %w[agent-alex Alex],
    %w[agent-carl Carl],
    %w[app-commercial-welding Commercial\ Welding],
    %w[app-cyvasse Cyvasse],
    %w[agent-avi Avi],
    %w[agent-shannon Shannon],
    %w[app-mcritchie-studio McRitchie\ Studio],
    %w[agent-mason Mason],
    %w[app-mcritchie-industries McRitchie\ Industries],
    %w[app-10and5 10&5],
    %w[agent-jasper Jasper],
    %w[agent-steffon Steffon],
    %w[app-voicebox Voicebox],
    %w[app-alex-build alex.build],
    %w[agent-mack Mack],
    %w[app-dads-app Dads\ App],
    %w[agent-hank Hank]
  ].freeze

  def logo_grid_tiles
    LOGO_GRID_TILES.map { |file, label| { src: image_path("logo_grid/#{file}.webp"), label: } }
  end
end
