# PFF grades: runs BEFORE 30_athlete_grades.rb so the flat placeholder only fills
# gaps for athletes no PFF file covered.
#
# The repo ships no PFF data (Alex McRitchie's ruling, 2026-11-01): the 11 CSVs left
# the tree because PFF's terms read as barring hosting. So on a clean checkout this
# seed imports nothing and says so on stderr. An operator holding a licensed export
# imports it with `bin/rails pff:import_dir DIR=path/to/dir SEASON=2025-nfl`, or
# places it in the gitignored db/seeds/data/pff/ and reseeds. Never commit it, and
# never host it elsewhere.
Pff::SeedGrades.new(season_slug: "2025-nfl").call
