require "test_helper"

# [unit] The two mascot evolution gates: a three-stage task Pokémon evolves one
# step when the work is REVIEWED, and every evolvable mascot advances when it
# ASSEMBLES (Charmander → Charmeleon → Charizard; Pikachu spends its one step at
# assemble, for Raichu). Both gates sit on the ACCEPTING side of the submit seam —
# handing work over is not the same as the work being taken. The SESSION's mascot
# never changes — only the task's copy.
class TaskMascotEvolutionTest < ActiveSupport::TestCase
  # Collision-proof against e2e seed leftovers in the shared test DB
  # (first_or_initialize + update! forces the attributes either way).
  def seed_family!(rows)
    rows.map do |dex, slug, base, evolution|
      Pokemon.where(slug: slug).first_or_initialize.tap do |pokemon|
        pokemon.update!(dex: dex, name: slug.capitalize, slug: slug, generation: 1,
                        base: base, evolution: evolution, baby: [])
      end
    end
  end

  def seed_charmander_line!
    seed_family!([[4, "charmander", "charmander", ["charmeleon"]],
                  [5, "charmeleon", "charmander", ["charizard"]],
                  [6, "charizard", "charmander", []]])
  end

  def seed_pikachu_line!
    seed_family!([[25, "pikachu", "pikachu", ["raichu"]],
                  [26, "raichu", "pikachu", []],
                  [172, "pichu", "pikachu", ["pikachu"]]])
    Pokemon.find_by!(slug: "pikachu").update!(baby: ["pichu"])
  end

  def make_task(mascot:, session: "sess-evo", shiny: false, stage: "building")
    task = Task.create!(title: "Evolution gate probe task")
    task.update_columns(stage: stage, metadata: {
                          "devops" => { "session_id" => session, "mascot" => mascot,
                                        "mascot_session" => session, "mascot_shiny" => shiny }
                        })
    task.reload
  end

  # Submitting is the builder handing the work over, not the work being accepted,
  # so it spends no gate at all — the mascot the board shows in `submitted` is the
  # one that built it.
  test "submitting spends no gate and leaves the mascot alone" do
    seed_charmander_line!
    task = make_task(mascot: "charmander")

    task.submit!

    assert_equal "charmander", task.reload.devops["mascot"]
    assert_nil task.devops["mascot_stage"]
  end

  test "three-stage mascot evolves one step at reviewed" do
    seed_charmander_line!
    task = make_task(mascot: "charmander")

    task.submit!
    task.review!

    assert_equal "charmeleon", task.reload.devops["mascot"]
    assert_equal 1, task.devops["mascot_stage"]
  end

  test "three-stage mascot evolves a second step at assembled" do
    seed_charmander_line!
    task = make_task(mascot: "charmander")

    task.submit!
    task.review!
    task.assemble!

    assert_equal "charizard", task.reload.devops["mascot"]
    assert_equal 2, task.devops["mascot_stage"]
  end

  test "a one-evolution mascot skips reviewed and evolves at assembled" do
    seed_pikachu_line!
    task = make_task(mascot: "pikachu")

    task.submit!
    task.review!

    assert_equal "pikachu", task.reload.devops["mascot"]
    assert_equal 1, task.devops["mascot_stage"]

    task.assemble!

    assert_equal "raichu", task.reload.devops["mascot"]
    assert_equal 2, task.devops["mascot_stage"]
  end

  test "a branching one-evolution line evolves into one random branch at assembled" do
    seed_family!([[133, "eevee", "eevee", %w[vaporeon jolteon flareon espeon umbreon]],
                  [134, "vaporeon", "eevee", []],
                  [135, "jolteon", "eevee", []],
                  [136, "flareon", "eevee", []],
                  [196, "espeon", "eevee", []],
                  [197, "umbreon", "eevee", []]])
    task = make_task(mascot: "eevee")

    task.submit!
    task.review!
    assert_equal "eevee", task.devops["mascot"]

    task.assemble!

    assert_includes %w[vaporeon jolteon flareon espeon umbreon], task.devops["mascot"]
    assert_equal 2, task.devops["mascot_stage"]
  end

  test "a single-stage mascot passes both gates unevolved but consumes them" do
    seed_family!([[143, "snorlax", "snorlax", []]])
    task = make_task(mascot: "snorlax")

    task.submit!
    task.review!

    assert_equal "snorlax", task.devops["mascot"]
    assert_equal 1, task.devops["mascot_stage"]

    task.assemble!

    assert_equal "snorlax", task.devops["mascot"]
    assert_equal 2, task.devops["mascot_stage"]
  end

  # A reviewed task can be bounced back for rework and come round again. The gate
  # is spent on the FIRST review, so the second one must not evolve it twice.
  test "a rework loop back through reviewed never double-evolves" do
    seed_charmander_line!
    task = make_task(mascot: "charmander")

    task.submit!
    task.review!
    assert_equal "charmeleon", task.devops["mascot"]

    task.block!(kind: "rework")
    task.build!
    task.submit!
    task.review!

    assert_equal "charmeleon", task.reload.devops["mascot"]
    assert_equal 1, task.devops["mascot_stage"]
  end

  test "assembling with a skipped review gate evolves one step only" do
    seed_charmander_line!
    task = make_task(mascot: "charmander")

    task.update!(stage: "assembled")

    assert_equal "charmeleon", task.devops["mascot"]
    assert_equal 2, task.devops["mascot_stage"]
  end

  test "the session's own mascot never changes while the task evolves" do
    seed_charmander_line!
    session = SessionMascot.create!(session_id: "sess-evo", mascot_slug: "charmander")
    task = make_task(mascot: "charmander", session: "sess-evo")

    task.submit!
    task.review!
    task.assemble!

    assert_equal "charmander", session.reload.mascot_slug
    # A sibling task in the same session still spawns at the base form.
    sibling = Task.create!(title: "Sibling adopts base form",
                           metadata: { "devops" => { "session_id" => "sess-evo" } })
    assert_equal "charmander", sibling.devops["mascot"]
  end

  test "a handoff resubmit starts the new session's line from its base" do
    seed_charmander_line!
    seed_family!([[158, "totodile", "totodile", ["croconaw"]],
                  [159, "croconaw", "totodile", ["feraligatr"]],
                  [160, "feraligatr", "totodile", []]])
    SessionMascot.create!(session_id: "sess-two", mascot_slug: "totodile")
    task = make_task(mascot: "charmander", session: "sess-one")

    task.submit!
    task.review!
    assert_equal "charmeleon", task.devops["mascot"]

    task.block!(by: "avi", kind: "rework")
    # A different agent picks it up: a block is a building attribute now, so the
    # handoff resubmits (clearing the block), swaps the session id, then re-claims
    # building — that fresh build transition swaps the mascot to the new session's
    # Pokémon and resets the consumed gate with the new line.
    task.update!(stage: "submitted")
    task.update!(metadata: task.metadata.deep_merge("devops" => { "session_id" => "sess-two" }))
    task.build!
    assert_equal "totodile", task.devops["mascot"]
    assert_nil task.devops["mascot_stage"]

    task.submit!
    task.review!
    assert_equal "croconaw", task.devops["mascot"]
    assert_equal 1, task.devops["mascot_stage"]
  end

  test "shiny carries through evolution with its sparkle" do
    seed_charmander_line!
    task = make_task(mascot: "charmander", shiny: true)

    task.submit!
    task.review!
    task.assemble!

    assert_equal "charizard", task.devops["mascot"]
    assert task.mascot_shiny?
    assert_includes task.devops["mascot_emoji"].to_s, "✨"
  end

  test "persona tasks never evolve" do
    seed_charmander_line!
    Agent.where(slug: "carl").first_or_initialize.update!(name: "Carl", slug: "carl")
    task = Task.create!(title: "Persona evolution probe",
                        metadata: { "devops" => { "persona" => "carl" } })
    task.update_columns(stage: "submitted")

    task.reload.review!

    assert_equal "Carl", task.devops["mascot"]
    assert_nil task.devops["mascot_stage"]
  end

  test "an unknown mascot slug leaves the gate unconsumed and unevolved" do
    task = make_task(mascot: "missingno")

    task.submit!
    task.review!

    assert_equal "missingno", task.devops["mascot"]
    assert_nil task.devops["mascot_stage"]
  end

  # mascot_stage is server-owned and NOT a DEVOPS_KEY, so a client that echoes a
  # normalized devops hash drops it — normalize_devops_metadata keeps only the
  # whitelist. A spent gate that reads back as unspent re-opens, and the rework
  # loop above evolves a SECOND time. sync_mascot_display carries it forward for
  # the same Pokémon, which is why this survives the wipe.
  #
  # NOTE the mechanism, since it moved: this drives `update!` on the MODEL, so it
  # covers any wholesale metadata assignment — the raw `metadata: {}` API door
  # included. The v1 devops PATCH itself no longer replaces the hash (it merges
  # since api-devops-patch-replaces), so omission alone no longer wipes this key.
  # The guard still earns its keep against the echo below.
  test "a spent gate survives a client devops write" do
    seed_charmander_line!
    task = make_task(mascot: "charmander")
    task.submit!
    task.review!
    assert_equal "charmeleon", task.devops["mascot"]

    # bin/task's read-modify-write: whitelisted client keys only, gate dropped.
    task.update!(metadata: { "devops" => Task.normalize_devops_metadata(task.devops) })
    assert_equal 1, task.reload.devops["mascot_stage"], "the spent review gate is restored"

    task.block!(kind: "rework")
    task.build!
    task.submit!
    task.review!

    assert_equal "charmeleon", task.reload.devops["mascot"], "a wiped gate must not re-evolve"
  end

  # The same wipe, seen from the handle: a write that DROPS the mascot must not hand
  # the task a different Pokémon on its next build-stage move.
  #
  # Same mechanism note as its sibling above: this drives `update!` on the MODEL, so
  # it covers any wholesale metadata assignment — the raw `metadata: {}` API door
  # included. The v1 devops PATCH merges since api-devops-patch-replaces, so mere
  # omission no longer reaches this guard; a name posted BLANK still does.
  test "a client write that omits the mascot keeps the task's Pokemon" do
    seed_charmander_line!
    task = make_task(mascot: "charmander", stage: "designed")

    task.update!(metadata: { "devops" => { "worktree_slug" => "evolution-gate-probe-task" } })
    task.build!

    assert_equal "charmander", task.reload.devops["mascot"]
    assert_equal "sess-evo", task.devops["mascot_session"]
  end
end
