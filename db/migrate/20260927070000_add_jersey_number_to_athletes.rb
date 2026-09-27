# THE FIELD THE OPERATOR NAMED THAT HAD NOWHERE TO GO.
#
# He described the define step as "name, height, and for athletes number and
# team". Four of those had columns; the number had none — measured 2026-09-26 and
# again 2026-09-27 against `db/schema.rb`: no `jersey_number`, no `number`, on
# athletes or on any other table, and every other "jersey" in the app means the
# free-text `colorway`. ESPN has been returning it as `athlete.jersey` the whole
# time and every reader dropped it on the floor, so the character-sheet recipe
# substitutes a `<NUMBER>` into every prompt and the orchestrator has been typing
# numbers from memory.
#
# INTEGER, NOT STRING, although ESPN sends "30". A number is a number: it sorts,
# it compares, and an integer cannot hold the two shapes a string column would
# eventually collect ("30" and "#30"). `Athletes::AcquireOrValidate` casts once,
# at the provider seam, and refuses a value that is not a plain number rather
# than storing a surprise.
#
# NULLABLE, and it has to be. 2,881 athletes exist with no number on file and no
# source consulted yet; a NOT NULL default of 0 would assert every one of them
# wears zero, which is worse than admitting we do not know.
#
# NOT INDEXED. Nothing looks an athlete up by number — the number is read off a
# row already in hand, for a prompt. An index here would be a write cost against
# a query nobody makes.
class AddJerseyNumberToAthletes < ActiveRecord::Migration[8.1]
  def change
    add_column :athletes, :jersey_number, :integer
  end
end
