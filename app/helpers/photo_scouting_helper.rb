# WHAT THE SCOUTING PAGE HANDS ALPINE.
#
# IN A HELPER BECAUSE OF THE x-data QUOTE TRAP. A JSON literal written into an
# `x-data` attribute carries double quotes, which close the attribute and leave the
# component undefined — the section then renders with every binding dead and nothing
# in the console worth finding. So the page seeds state through `data-` attributes
# instead, where ERB's own escaping handles the quotes and the browser un-escapes them
# into `dataset`. Building those payloads here keeps four long `to_json` expressions
# out of the markup.
module PhotoScoutingHelper
  # THE OPERATOR'S CURRENT VERDICT PER CANDIDATE, for the button states.
  def scouting_verdicts_json(photos)
    photos.to_h { |photo| [photo.slug, photo.operator_verdict] }.to_json
  end

  # WHICH AGREEMENT CELL EACH CANDIDATE IS IN, computed SERVER-SIDE.
  #
  # Seeded as an answer rather than as ingredients on purpose. The client could derive
  # it from `chosen` and the verdict, but that would be a second copy of
  # AppearanceReferencePhoto#calibration_state written in another language — and the
  # two would drift the first time a cell was renamed. The write path returns the same
  # field for the same reason, so the client never computes a cell at all.
  def scouting_states_json(photos)
    photos.to_h { |photo| [photo.slug, photo.calibration_state] }.to_json
  end

  # THE CELL COPY AND ITS TEXT COLOUR, so the live chip reads the same words the
  # server-rendered chip does.
  #
  # ONLY THE `text-` UTILITY IS PASSED, not the whole chip class string: the live
  # element is a line of prose under the buttons rather than a badge, so a background
  # and a border would draw a second box inside the tile. Picking the utility out of
  # the shared constant keeps one definition of the palette.
  def scouting_cells_json
    AppearancesHelper::CALIBRATION_CHIPS.transform_values { |chip|
      { label: chip[:label], text: text_utility(chip[:classes]) }
    }.to_json
  end

  def text_utility(classes)
    classes.split.find { |token| token.start_with?("text-") } || "text-muted"
  end
end
