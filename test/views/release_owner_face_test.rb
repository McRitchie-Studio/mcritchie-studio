require "test_helper"

# [component] The conductor owner-face partial — one release-conductor Pokémon
# face on the Next Release card (assembler = QA / qa-release, deployer =
# production-deploy). Guards the two things this change touches at the component
# level: the sprite renders a touch larger than the 24px conductor-mascot row,
# and a live claim keeps its ring while an idle (lapsed-lease) claim dims and
# drops it. Placement beside the status badge is covered by the [integration]
# test/integration/deployments_owner_faces_test.rb.
class ReleaseOwnerFaceTest < ActionView::TestCase
  setup do
    @pokemon = Pokemon.create!(dex: 236, name: "Tyrogue", slug: "tyrogue",
                               types: %w[fighting], generation: 2,
                               sprite_url: "https://img.test/tyrogue.png")
  end

  test "renders a 28px sprite, a touch larger than the 24px mascot row" do
    render partial: "tasks/release_owner_face", locals: face_locals(live: true)

    assert_includes rendered, "width=\"28\" height=\"28\""
    assert_includes rendered, "w-7 h-7 shrink-0"
    refute_includes rendered, "w-6 h-6"
  end

  test "a live claim keeps the ring and is not dimmed" do
    render partial: "tasks/release_owner_face", locals: face_locals(live: true)

    assert_includes rendered, "ring-2 ring-primary/50 rounded-full"
    assert_includes rendered, "data-live=\"true\""
    refute_includes rendered, "opacity-50"
  end

  test "an idle (lapsed-lease) claim dims and drops the ring" do
    render partial: "tasks/release_owner_face", locals: face_locals(live: false)

    refute_includes rendered, "ring-2 ring-primary/50 rounded-full"
    assert_includes rendered, "opacity-50"
    assert_includes rendered, "data-live=\"false\""
  end

  private

  def face_locals(live:)
    { role: "assembler", pokemon: @pokemon, name: @pokemon.name,
      label: "QA (assembler): Tyrogue", shiny: false, live: live }
  end
end
