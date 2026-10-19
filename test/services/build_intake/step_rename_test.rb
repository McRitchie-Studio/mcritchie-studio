require "test_helper"

# [unit] The theme step's rename (task build-flow-polish): the step Ray asks
# second was named "colors" while the visitor read "Theme". It is "theme" now.
# The name was never stored (a request holds its theme in `palette`), so a
# draft saved before the rename reads exactly as before, and anything still
# asking for "colors" gets the theme's answer.
class BuildIntakeStepRenameTest < ActiveSupport::TestCase
  PALETTE = { "name" => "Pitch",
              "light" => { "primary" => "#15803d", "accent" => "#f59e0b", "surface" => "#ffffff", "text" => "#111827" },
              "dark" => { "primary" => "#4ade80", "accent" => "#fbbf24", "surface" => "#0b1220", "text" => "#f1f5f9" } }.freeze

  test "[unit] the step is theme, in the asking order, and the old name resolves to it" do
    assert_equal %w[idea theme cto address], BuildIntake::STEPS
    assert_equal "theme", BuildIntake.step("colors")
    assert_equal "theme", BuildIntake.step(:colors)
    assert_equal "cto", BuildIntake.step("cto"), "a current name is itself"
  end

  test "[unit] a draft saved before the rename (theme picked, nothing else) still reads its theme" do
    # What an old draft holds: the palette column, written by a theme tap. The
    # step name was never part of the row.
    draft = AppRequest.create!(prompt: "A league site")
    AppRequest.where(id: draft.id).update_all(palette: PALETTE, answers: { "title" => "League Hub", "idea" => "League Hub" })
    draft = AppRequest.find(draft.id)

    checklist = draft.intake_checklist
    assert_equal %w[idea theme cto address], checklist.keys, "each step once, in the asking order"
    assert_equal true, checklist["theme"]
    assert_equal true, checklist["colors"], "the old name still reads the theme's value"
    assert_equal false, AppRequest.create!(prompt: "x").intake_checklist["colors"], "and an unset theme reads unset"
    assert_nil checklist["nonsense"], "only a retired step name is aliased"
    refute_includes checklist.to_json, "colors", "Ray's context carries the new name only"
    assert_equal "cto", draft.next_intake_step, "the theme is set, so the CTO is next"
    assert draft.intake_started?
    refute draft.intake_complete?
  end

  test "[unit] the status card's Theme tile reads the saved theme" do
    draft = AppRequest.create!(prompt: "A league site", answers: { "title" => "League Hub", "idea" => "League Hub" }, palette: PALETTE)
    html = ApplicationController.render(partial: "build/status_card", locals: { request_row: draft, started: true })
    tile = Nokogiri::HTML.fragment(html).at_css("[data-test=build-tile-theme]")
    assert tile, "the Theme tile renders"
    assert_equal "true", tile["data-done"]
    assert_includes tile.text, "Pitch", "the tile names the saved theme"
  end
end
