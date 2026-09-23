require "test_helper"

# [integration] The inspection gate across its whole boundary: confirm the
# jersey, attach each artifact, approve — and the refusals that keep the gate
# meaningful.
class ArtifactGateTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:alex)
    Artifact.delete_all
    Appearance.delete_all
    Content.where(workflow: "rapper_replace").destroy_all

    @burrow = Person.create!(first_name: "Joe", last_name: "Burrow", athlete: true)
    @chase  = Person.create!(first_name: "JaMarr", last_name: "Chase", athlete: true)
    Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals white", colorway: "white")
    Appearance.create!(person_slug: @chase.slug,  descriptor: "Bengals white", colorway: "white")

    @content = Content.create!(
      title: "Burrow And Chase Torch Jaguars", workflow: "rapper_replace", stage: "idea",
      qb_player_slug: @burrow.slug, skill_player_slug: @chase.slug,
      game_facts: { "winner_slug" => "cincinnati-bengals",
                    "away_team_slug" => "cincinnati-bengals",
                    "home_team_slug" => "jacksonville-jaguars" }
    )
    log_in_as(@admin)
  end

  def slots = Content::ArtifactPlan.new(@content.reload).slots

  def attach(index, url = "/x.png")
    post attach_artifact_content_path(@content.slug),
         params: { slot_index: index, image_url: url }
  end

  def index_of(kind) = slots.index { |s| s.kind == kind }

  def appearances_for(person, colorway) = Appearance.find_by!(person_slug: person.slug, colorway: colorway)

  def attach_all = slots.each_index { |i| attach(i) }

  # The submit label for ONE slot's form. The page carries three, so scanning the
  # whole body counts every one of them — which is right for the all-slots-agree
  # tests above and useless for a single mixed slot.
  def submit_label_for(kind)
    css_select("form[data-test='attach-#{kind}'] input[type=submit]").first&.[]("value")
  end

  # A pair artifact with one recorded look and one that was never recorded.
  def pair_artifact(url, qb_appearance, skill_person)
    Artifact.create!(kind: "pair", image_url: url).tap do |a|
      a.subjects.create!(person_slug: @burrow.slug, appearance_slug: qb_appearance.slug,
                         role: "qb", ordinal: 1)
      a.subjects.create!(person_slug: skill_person.slug, appearance_slug: nil,
                         role: "skill", ordinal: 2)
    end
  end

  # --- component tier ------------------------------------------------------

  test "[component] the gate renders a slot per artifact with its decision" do
    get content_path(@content.slug)

    assert_response :success
    assert_match "Artifact Inspection", response.body
    assert_match "Both players", response.body
    assert_match "Quarterback", response.body
    assert_match "Skill player", response.body
    assert_equal 3, response.body.scan("GENERATE").length
  end

  test "[component] an unconfirmed colorway is labelled a guess" do
    get content_path(@content.slug)

    assert_match "GUESSED FROM HOME/AWAY", response.body
    assert_no_match(/CONFIRMED/, response.body)
  end

  # Each subject's own look is shown, because a mixed cast carries different
  # looks in one frame.
  test "[component] every subject's look is named on the slot" do
    get content_path(@content.slug)

    assert_match "Joe Burrow: Bengals white", response.body
    assert_match "JaMarr Chase: Bengals white", response.body
  end

  # THE SUBMIT LABEL IS A PROMISE ABOUT THE OPERATOR'S EXISTING ASSETS, and on a
  # re-skin slot it promised the opposite of what happens. `slot.artifact` on a
  # re-skin is the OTHER colorway, and its image_url IS present, so the label
  # read "Replace" on every slot while the attach keeps that artifact and adds a
  # second one beside it. That label was true while the attach retired its
  # source; it became false the moment the retire was made conditional. Telling
  # the operator an asset will be destroyed when it will be kept is the inverse
  # of the bug that change fixed, on the one screen whose job is trust about
  # assets.
  test "[component] a re-skin slot offers Attach, never Replace" do
    attach_all
    post set_colorway_content_path(@content.slug), params: { colorway: "black" }
    assert slots.all?(&:reskin?),
           "the control — these must be re-skins, or this test proves nothing. " \
           "Read #{slots.map(&:decision).inspect}"

    get content_path(@content.slug)

    assert_equal 3, response.body.scan(/value="Attach"/).length,
                 "every re-skin slot must offer Attach — the white artifact is kept, not replaced"
    assert_equal 0, response.body.scan(/value="Replace"/).length,
                 "a re-skin replaces nothing; Replace here tells the operator his asset is about to be destroyed"
  end

  # The other half of the predicate, and the reason it is not simply "always
  # Attach": a :reuse slot holds the SAME cast in the SAME look, the attach DOES
  # retire it (contents_controller: `slot.occupant&.retire!`, and on a :reuse
  # slot `occupant` IS `artifact`), and Replace is the honest word. A fix that
  # flipped every label would break this.
  test "[component] a reuse slot still offers Replace" do
    attach_all
    assert slots.all?(&:reuse?),
           "the control — these must be reuses, or this test proves nothing. " \
           "Read #{slots.map(&:decision).inspect}"

    get content_path(@content.slug)

    assert_equal 3, response.body.scan(/value="Replace"/).length,
                 "a reuse attach retires the artifact it shows, so Replace is what happens"
    assert_equal 0, response.body.scan(/value="Attach"/).length
  end

  # An empty slot has no artifact to speak of either way.
  test "[component] a generate slot offers Attach" do
    get content_path(@content.slug)

    assert_equal 3, response.body.scan(/value="Attach"/).length
    assert_equal 0, response.body.scan(/value="Replace"/).length
  end

  # THE LABEL AND THE RETIRE CAME APART A SECOND TIME, from the other side.
  #
  # `slot.reuse?` was the right question only while the retire was spelled
  # `if slot.reuse?`. Once the retire began naming its own target
  # (`slot.occupant&.retire!`), a population moved out of :reuse while STILL
  # being superseded — a lookless artifact under a named colorway reads :reskin
  # — and the button went on asking the old question. It said "Attach", meaning
  # "your picture is safe", and the click retired the picture on the card.
  #
  # That is the exact inverse of the defect the three tests above were written
  # for, on the same button, and neither PR produced it alone: the retire split
  # and the label predicate landed on separate branches and composed into it.
  test "[component] a superseded lookless artifact still offers Replace" do
    bare = Person.create!(first_name: "Bare", last_name: "Look", athlete: true)
    @content.update!(qb_player_slug: bare.slug, skill_player_slug: nil, colorway: "black")
    i = index_of("character_sheet")
    attach(i, "/first.png")

    slot = slots[i]
    assert slot.reskin?,
           "the control — the refusal must have moved this OUT of :reuse, or the old " \
           "predicate would answer correctly by accident. Read #{slot.decision.inspect}"
    assert_not_nil slot.occupant,
           "the control — a row must occupy this cell, or nothing is retired and Attach " \
           "would be the honest word"
    assert_equal slot.artifact.id, slot.occupant.id,
           "the control — on a SINGLE-member cast the recolor source and the occupant are the " \
           "same row, so this test cannot tell the two apart. The mixed-cast test below is the " \
           "one that separates them"

    get content_path(@content.slug)

    assert_equal "Replace", submit_label_for("character_sheet"),
                 "the attach retires the very artifact on this card. Attach here promises " \
                 "the operator his image survives the click, and it does not"
  end

  # THE TWO ROWS, PULLED APART. A look nobody recorded for ONE member keeps the
  # black row out of :reuse while leaving it the cell occupant — the only way
  # `artifact` and `occupant` come apart and stay apart.
  #
  # THIS TEST USED TO ASSERT "Attach" HERE, and that was right while the card
  # rendered the recolor source: the white pair was on screen, the click retired
  # a different black row, and "Replace" would have named a destruction of the
  # picture the operator was looking at. The card now renders the OCCUPANT, so
  # the picture on screen is the black row and the click does destroy it —
  # "Replace" became the honest word by the same reasoning that chose "Attach"
  # before. The button's contract is unchanged; the row it describes moved.
  #
  # That also cost this test its old job. It was the sole discriminator against
  # `occupant&.image_url.present?`, which worked because the retired row was not
  # the row on screen — a state the card change makes unreachable. The
  # discriminator now lives in "an occupant filed without an image still offers
  # Replace", where the ROW and the PICTURE come apart instead.
  test "[component] a re-skin over a different row shows and replaces the occupant" do
    unrecorded = Person.create!(first_name: "Unre", last_name: "Corded", athlete: true)
    black = Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals black", colorway: "black")
    @content.update!(skill_player_slug: unrecorded.slug, colorway: "black")
    assert_equal 0, unrecorded.appearances.count,
                 "the control — this person's look is never recorded, which is what keeps " \
                 "the black artifact out of :reuse"

    white_pair = pair_artifact("/white-pair.png", appearances_for(@burrow, "white"), unrecorded)
    black_pair = pair_artifact("/black-pair.png", black, unrecorded)

    slot = slots[index_of("pair")]
    assert slot.reskin?, "the control — read #{slot.decision.inspect}"
    assert_equal white_pair.id, slot.artifact&.id,
                 "the control — the card must be showing the WHITE pair, the row we recolor from"
    assert_equal black_pair.id, slot.occupant&.id,
                 "the control — the row occupying this cell must be the BLACK one. If these " \
                 "two ever name the same artifact this test proves nothing"

    get content_path(@content.slug)

    assert_match "/black-pair.png", response.body,
                 "the black row is what is filed for this cast in this jersey; the card shows " \
                 "what is on file"
    assert_no_match(%r{/white-pair\.png}, response.body,
                    "the white pair is the row we would recolor FROM. Naming it in words is the " \
                    "job of `slot.detail`; putting it in the image frame is the wrong-jersey lie")
    assert_equal "Replace", submit_label_for("pair"),
                 "the click retires the black row, which is the picture now on this card"

    attach(index_of("pair"), "/new-pair.png")

    assert_nil white_pair.reload.retired_at,
               "and the label was telling the truth: the shown artifact is still live"
    assert_not_nil black_pair.reload.retired_at, "while the cell occupant was superseded"
  end

  # --- the cell occupant, on every consumer -------------------------------
  #
  # THE REFUSAL HAS A SECOND LIMB. `Artifact.matching` refuses a named colorway
  # over an unrecorded look, so on a MIXED CAST — one member's look recorded for
  # this colorway, one member's never recorded — `exact` is nil FOREVER. No
  # image the operator files can ever become one, because the refusal is about
  # the unrecorded PERSON, not about the artifact. `decide` therefore parks on
  # :reskin permanently, and `slot.artifact` on a :reskin is the OTHER-colorway
  # row we recolor FROM.
  #
  # Four consumers read that row as though it were the one on file: the card's
  # thumbnail, `#ready?`, and the gate's two reads in #approve_artifacts. The
  # first pass separated the LABEL from the MUTATION and stopped there; these
  # are the same separation, one population wider.
  #
  # Measured on this code 2026-09-23: after attaching /new-pair.png the card
  # still rendered /white-pair.png and the page did not contain the new image
  # at all. Reverting only the `colorway:` argument in #decide flips every cell
  # back to :reuse — the defect rides the refusal, exactly as in the first pass.

  test "[integration] the gate shows the image just attached, not the row it recolors from" do
    unrecorded = Person.create!(first_name: "Unre", last_name: "Corded", athlete: true)
    Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals black", colorway: "black")
    @content.update!(skill_player_slug: unrecorded.slug, colorway: "black")
    white_pair = pair_artifact("/white-pair.png", appearances_for(@burrow, "white"), unrecorded)

    assert slots[index_of("pair")].reskin?,
           "the control — the refusal must park this on :reskin, or `artifact` and the cell " \
           "occupant never come apart. Read #{slots[index_of('pair')].decision.inspect}"

    attach(index_of("pair"), "/new-pair.png")

    slot = slots[index_of("pair")]
    assert slot.reskin?,
           "the control — attaching must NOT resolve the refusal; that is what makes the stale " \
           "row survive on the card. Read #{slot.decision.inspect}"
    assert_equal white_pair.id, slot.artifact&.id,
           "the control — the recolor source must still be the white pair, or the two rows " \
           "agree and this test proves nothing"

    get content_path(@content.slug)

    assert_match "/new-pair.png", response.body,
                 "the operator just filed this image; a gate whose job is that a human looked " \
                 "at the picture must show the picture"
    assert_no_match(%r{/white-pair\.png}, response.body,
                    "the white pair belongs to another game. Rendering it in the slot's image " \
                    "position is the wrong-jersey confusion this screen exists to stop")
  end

  # AND THE GATE CLOSES OVER IT. The same stale row is what #ready? counts and
  # what #approve_artifacts stamps, so the operator's image is not merely
  # invisible — approval lands on the other colorway's artifact.
  test "[integration] approving stamps the artifact on file, not the recolor source" do
    unrecorded = Person.create!(first_name: "Unre", last_name: "Corded", athlete: true)
    Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals black", colorway: "black")
    @content.update!(skill_player_slug: unrecorded.slug, colorway: "black")
    white_pair = pair_artifact("/white-pair.png", appearances_for(@burrow, "white"), unrecorded)

    slots.each_with_index do |slot, i|
      attach(i, slot.kind == "pair" ? "/new-pair.png" : "/sheet-#{i}.png")
    end
    new_pair = Artifact.find_by!(image_url: "/new-pair.png")
    assert_equal white_pair.id, slots[index_of("pair")].artifact&.id,
                 "the control — the pair slot must still be pointing at the white row, or the " \
                 "approve below cannot land on the wrong artifact"

    post approve_artifacts_content_path(@content.slug)

    assert @content.reload.artifacts_approved?,
           "the control — the gate must actually open, or nothing is stamped either way. " \
           "Read #{flash[:alert].inspect}"
    assert new_pair.reload.approved?,
           "the image the operator filed for THIS game is the one the gate signs off"
    assert_not white_pair.reload.approved?,
           "approving the other colorway's artifact is the gate closing over the wrong jersey — " \
           "the one outcome this screen exists to prevent"
  end

  # AND THE GATE'S OWN LOCK, which is the same read twice more: #ready? draws
  # the Approve button enabled or disabled, and #approve_artifacts refuses on
  # its own before stamping anything. Both asked `artifact&.image_url.present?`
  # — the RECOLOR SOURCE on a :reskin — so a slot holding nothing for THIS game
  # counted as ready, the button came up live, and the POST went through and
  # stamped the other colorway's row.
  #
  # That is the gate failing in the one direction it must never fail: it
  # records that a human approved an image which is not in play. Every other
  # slot here is genuinely filled on purpose, so the refusal can only be coming
  # from the pair.
  test "[integration] the recolor source alone does not open the gate" do
    unrecorded = Person.create!(first_name: "Unre", last_name: "Corded", athlete: true)
    black = Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals black", colorway: "black")
    @content.update!(skill_player_slug: unrecorded.slug, colorway: "black")

    white_pair = pair_artifact("/white-pair.png", appearances_for(@burrow, "white"), unrecorded)
    qb_sheet = Artifact.create!(kind: "character_sheet", image_url: "/qb-black.png")
    qb_sheet.subjects.create!(person_slug: @burrow.slug, appearance_slug: black.slug, role: "qb", ordinal: 1)
    skill_sheet = Artifact.create!(kind: "character_sheet", image_url: "/skill.png")
    skill_sheet.subjects.create!(person_slug: unrecorded.slug, appearance_slug: nil, role: "skill", ordinal: 1)

    plan = Content::ArtifactPlan.new(@content.reload)
    pair = plan.slots[index_of("pair")]
    assert_equal white_pair.id, pair.artifact&.id,
                 "the control — the pair slot's only artifact must be the recolor source"
    assert_nil pair.occupant,
               "the control — nothing may be filed for this cast in this jersey, or the gate " \
               "is entitled to open and this test proves nothing"
    assert plan.slots.reject { |s| s.kind == "pair" }.all? { |s| s.occupant&.image_url.present? },
           "the control — every OTHER slot must be genuinely filled, or the refusal below " \
           "could be coming from one of them instead"

    assert_not plan.ready?,
               "a slot whose only artifact belongs to another game is not ready, however " \
               "present that artifact's image_url is"

    get content_path(@content.slug)
    assert_match "every slot needs an image before this unlocks", response.body,
                 "the operator must see the gate is shut; an enabled Approve here invites the " \
                 "click that stamps the wrong jersey"

    post approve_artifacts_content_path(@content.slug)

    assert_not @content.reload.artifacts_approved?,
               "the gate's own refusal is the last line — it must not depend on the button " \
               "having been drawn disabled"
    assert_not white_pair.reload.approved?,
               "and the recolor source is emphatically not what a click here would sign off"
  end

  # AND THE BUTTON STILL DOES NOT TEST FOR A PICTURE. `#replaces_filed_artifact?`
  # asks which ROW dies, never whether that row has an image: an artifact filed
  # with a blank URL — the attach form submitted empty — still occupies the cell
  # and is still destroyed by the next click. `occupant&.image_url.present?` is
  # the tempting shorter form and says "Attach" here, promising the operator
  # that nothing is lost.
  #
  # This is the discriminator that the mixed-cast test below used to carry. Once
  # the card renders the occupant, "the row on screen is not the row retired"
  # stops being reachable, so the shorter form has to be separated from the real
  # predicate somewhere the ROW and the PICTURE come apart instead.
  test "[component] an occupant filed without an image still offers Replace" do
    bare = Person.create!(first_name: "Bare", last_name: "Look", athlete: true)
    @content.update!(qb_player_slug: bare.slug, skill_player_slug: nil, colorway: "black")
    attach(index_of("character_sheet"), "")

    slot = slots[index_of("character_sheet")]
    assert_not slot.occupant.nil?,
               "the control — a row must occupy this cell, or there is nothing to replace"
    assert_not slot.occupant.image_url.present?,
               "the control — that row must carry NO image, or this is not the case where the " \
               "row and the picture come apart. Read #{slot.occupant.image_url.inspect}"

    get content_path(@content.slug)

    assert_equal "Replace", submit_label_for("character_sheet"),
                 "the next attach retires this row. Attach here promises the operator that " \
                 "nothing on file is destroyed, and a row is"
  end

  test "[component] the gate disappears once approved" do
    @content.update!(artifacts_approved_at: Time.current)
    get content_path(@content.slug)

    assert_no_match(/Artifact Inspection/, response.body)
  end

  # --- integration tier ----------------------------------------------------

  test "confirming the jersey stops it reading as a guess" do
    post set_colorway_content_path(@content.slug), params: { colorway: "Black" }

    assert_equal "black", @content.reload.colorway
    get content_path(@content.slug)
    assert_match "CONFIRMED", response.body
  end

  # The ceiling this model exists to remove: a pair is two subject rows.
  test "attaching a pair files both people as subjects" do
    attach(index_of("pair"))

    artifact = Artifact.find_by(kind: "pair")
    assert_equal 2, artifact.subjects.count
    assert_equal [@burrow.slug, @chase.slug].sort, artifact.subjects.map(&:person_slug).sort
  end

  test "a character sheet files exactly one subject" do
    attach(index_of("character_sheet"))

    assert_equal 1, Artifact.find_by(kind: "character_sheet").subjects.count
  end

  # Supersede rather than delete: the old image stays as the record of what was
  # published before.
  test "replacing an image retires the old artifact rather than deleting it" do
    i = index_of("character_sheet")
    attach(i, "/one.png")
    attach(i, "/two.png")

    assert_equal 1, Artifact.live.where(kind: "character_sheet").count
    assert_equal 1, Artifact.where(kind: "character_sheet").where.not(retired_at: nil).count
  end

  test "approving stamps every artifact and the content" do
    attach_all

    post approve_artifacts_content_path(@content.slug)

    assert @content.reload.artifacts_approved?
    assert_equal 3, Artifact.approved.count
  end

  # The gate's whole job: refuse until a human could have looked at them all.
  test "approving is refused while a slot is empty" do
    attach(index_of("pair"))

    post approve_artifacts_content_path(@content.slug)

    assert_not @content.reload.artifacts_approved?
    assert_match(/needs an image/, flash[:alert])
  end

  # Changing the jersey re-decides every slot — colorway is part of an
  # artifact's identity, not a detail on it.
  test "changing the colorway turns reuses into re-skins" do
    attach_all
    post approve_artifacts_content_path(@content.slug)
    assert slots.all?(&:reuse?)

    post set_colorway_content_path(@content.slug), params: { colorway: "black" }

    assert slots.all?(&:reskin?),
           "artifacts approved in white must read as re-skins once the jersey changes"
  end

  # --- the repeat case: the same pair, a different jersey, then back -------
  #
  # This is the case the screen was built for. A face does not change week to
  # week; only the jersey does. So filing the black recolor must not cost the
  # white artifact — and the test that proves it has to run the WHOLE cycle,
  # because the defect was invisible after two attaches and only showed on the
  # third.

  test "attaching a re-skin leaves the other colorway live" do
    Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals black", colorway: "black")
    Appearance.create!(person_slug: @chase.slug,  descriptor: "Bengals black", colorway: "black")

    attach_all
    assert_equal 3, Artifact.live.count, "the white set is on file"

    post set_colorway_content_path(@content.slug), params: { colorway: "black" }
    assert slots.all?(&:reskin?), "the control — these must be re-skins, or this proves nothing"

    attach_all

    assert_equal 6, Artifact.live.count,
                 "filing the black recolor retired the white artifacts it was re-skinned FROM — " \
                 "the library can then hold only one live artifact per cast, and the reuse this " \
                 "screen exists for is impossible"
    assert_equal 0, Artifact.where.not(retired_at: nil).count,
                 "a re-skin supersedes nothing; nothing should have been retired"
  end

  # The third pass is the one that bites: white, black, then white again. With
  # the unconditional retire the white artifacts are gone by now, so the gate
  # bills a RECOLOR for a jersey it already had on file — it reads `:reskin`
  # off the black artifact instead of `:reuse` off the white one. It does not
  # ask for a fresh generation: every attach files a replacement in the same
  # transaction, so the cast never drops to zero live artifacts and `:generate`
  # is unreachable here. Measured by reinstating the unconditional retire —
  # this pass then prints [:reskin, :reskin, :reskin].
  test "a jersey the pair has worn before still reads reuse on the way back" do
    Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals black", colorway: "black")
    Appearance.create!(person_slug: @chase.slug,  descriptor: "Bengals black", colorway: "black")

    attach_all                                                              # white
    post set_colorway_content_path(@content.slug), params: { colorway: "black" }
    attach_all                                                              # black
    post set_colorway_content_path(@content.slug), params: { colorway: "white" }

    assert slots.all?(&:reuse?),
           "back in white, every slot must read REUSE — the artifacts are still on file. " \
           "Read #{slots.map(&:decision).inspect}"
  end

  # --- the colliding empty look -------------------------------------------
  #
  # Zero appearances is every person's state until their first look is filed, so
  # this is the common path on a fresh person, not a corner. The gate card still
  # renders the real image — a human looking at the screen sees the picture, which
  # is the gate's whole job — but the DECISION LABEL said "Reuse" over an artifact
  # whose jersey nobody had recorded, and the label is what an operator trusts
  # when skimming.

  test "[integration] a named colorway does not reuse an artifact whose look was never recorded" do
    bare = Person.create!(first_name: "Bare", last_name: "Look", athlete: true)
    @content.update!(qb_player_slug: bare.slug, skill_player_slug: nil, colorway: "black")

    artifact = Artifact.create!(kind: "character_sheet", image_url: "/x.png", approved_at: Time.current)
    artifact.subjects.create!(person_slug: bare.slug, appearance_slug: nil, ordinal: 1)

    sheet = slots.find { |s| s.kind == "character_sheet" }

    assert_not sheet.reuse?,
               "the request named black and this person has no black look; an artifact whose look " \
               "was never recorded cannot be known to satisfy it. Read #{sheet.decision.inspect}"
    assert sheet.reskin?, "the face work is done and only the wardrobe is unknown — that is a recolor"
    assert_equal "have an artifact for this cast with no look recorded — recolor for this game",
                 sheet.detail,
                 "the re-skin sentence used to lose its object here: every descriptor is nil, so " \
                 "the list compacted to empty and the card read 'have  — recolor for this game'"
  end

  # AND THE PARTIAL CAST, which the empty-list guard above does not reach. One
  # look recorded and one not is the ordinary state while a person's looks are
  # being filed, and compacting the nils away deleted the unknown person from
  # the sentence — "have Bengals white" over an artifact whose second look
  # nobody has described. Same defect as the empty list losing its object, one
  # case short.
  test "[component] the re-skin sentence counts the looks it does not know" do
    unrecorded = Person.create!(first_name: "Unre", last_name: "Corded", athlete: true)
    Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals black", colorway: "black")
    @content.update!(skill_player_slug: unrecorded.slug, colorway: "black")
    pair_artifact("/white-pair.png", appearances_for(@burrow, "white"), unrecorded)

    slot = slots[index_of("pair")]

    assert slot.reskin?, "the control — read #{slot.decision.inspect}"
    assert_equal 1, slot.artifact.subjects.count { |sub| sub.effective_appearance.nil? },
                 "the control — exactly one subject's look must be unrecorded, or this is not " \
                 "the partial case"
    assert_equal "have Bengals white, plus 1 look never recorded — recolor for this game",
                 slot.detail,
                 "compacting the nils away drops the unknown person from the sentence and " \
                 "claims we know a look we have never been told"
  end

  test "[integration] the gate page stops claiming an approved artifact is on file" do
    bare = Person.create!(first_name: "Bare", last_name: "Look", athlete: true)
    @content.update!(qb_player_slug: bare.slug, skill_player_slug: nil, colorway: "black")
    artifact = Artifact.create!(kind: "character_sheet", image_url: "/x.png", approved_at: Time.current)
    artifact.subjects.create!(person_slug: bare.slug, appearance_slug: nil, ordinal: 1)

    get content_path(@content.slug)

    assert_response :success
    assert_no_match(/approved artifact on file/, response.body,
                    "that sentence is the reuse detail, and reuse is exactly what this must not be")
  end

  # AND THE LEGITIMATE EMPTY MATCH SURVIVES. With no colorway to resolve — no
  # confirmation and no game facts to guess from — there is nothing for the
  # artifact to contradict, and refusing here would make the gate offer to
  # regenerate an image it is already holding.
  test "[integration] with no colorway at all a lookless artifact is still reused" do
    bare = Person.create!(first_name: "Bare", last_name: "Look", athlete: true)
    @content.update!(qb_player_slug: bare.slug, skill_player_slug: nil, colorway: nil, game_facts: {})
    artifact = Artifact.create!(kind: "character_sheet", image_url: "/x.png", approved_at: Time.current)
    artifact.subjects.create!(person_slug: bare.slug, appearance_slug: nil, ordinal: 1)

    sheet = slots.find { |s| s.kind == "character_sheet" }

    assert_nil Content::ArtifactPlan.new(@content.reload).colorway,
               "the control — with no confirmation and no game facts there is no colorway to resolve"
    assert sheet.reuse?, "nothing was asked for, so nothing is contradicted. Read #{sheet.decision.inspect}"
  end

  # The supersede itself must still happen, or the fix above has simply turned
  # the retire off. Same cast, same look, a new image: that one IS a replacement.
  test "a reuse attach still retires the artifact it replaces" do
    i = index_of("pair")
    attach(i, "/first.png")
    assert slots[i].reuse?, "the control — the second attach must be deciding REUSE"

    attach(i, "/second.png")

    assert_equal 1, Artifact.live.where(kind: "pair").count
    assert_equal 1, Artifact.where(kind: "pair").where.not(retired_at: nil).count
  end

  # --- the look an attach files -------------------------------------------
  #
  # THE WRITE, not a reader. The attach filed `appearance_slug: nil` whenever
  # the content named a colorway the person had no look in, while every read
  # resolves nil to the person's DEFAULT — so the row went in under
  # `person@<default>` and the lookup asked for `person@`. Three consumer
  # censuses could not see it, because every consumer was correct.
  #
  # It is reachable on the ordinary path, not on unusual operator input: this
  # cast's only filed look is Bengals white, and a HOME win guesses "primary",
  # which is half of all games.

  # Put the Bengals at home so `guessed_colorway` answers "primary" — a colorway
  # neither player has a look in.
  def home_win!
    @content.update!(game_facts: { "winner_slug" => "cincinnati-bengals",
                                   "away_team_slug" => "jacksonville-jaguars",
                                   "home_team_slug" => "cincinnati-bengals" })
  end

  def assert_unfiled_colorway
    assert_equal "primary", Content::ArtifactPlan.new(@content.reload).colorway,
                 "the control — the guess must be primary, or this test proves nothing"
    assert_equal [], Appearance.live.where(colorway: "primary").pluck(:person_slug),
                 "the control — nobody may have a primary look yet, or this test proves nothing"
  end

  test "an attach for an unfiled colorway records the look it was uploaded for" do
    home_win!
    assert_unfiled_colorway

    attach(index_of("pair"))

    filed = Artifact.find_by(kind: "pair").subjects.map(&:appearance_slug)
    assert_equal 2, filed.compact.length, "both subjects must carry a look, not a null"
    assert_equal ["primary", "primary"],
                 Appearance.where(slug: filed).pluck(:colorway),
                 "the look filed must be the colorway the image was uploaded FOR"
  end

  # ACCEPTANCE 2: a filed artifact is found by its own lookup. Before the write
  # recorded the look this read :reskin forever — the slot that created the
  # artifact could not see it.
  test "the slot finds the artifact it just created" do
    home_win!
    assert_unfiled_colorway

    attach_all

    assert_equal [:reuse, :reuse, :reuse], slots.map(&:decision),
                 "every slot must find its own artifact; :reskin means the lookup missed it"
  end

  # THE OPERATOR-VISIBLE FAILURE. A miss on the exact match leaves the slot on
  # :reskin, so the attach never retires what it replaces: the library doubles
  # and the page keeps rendering the FIRST image while the operator pastes new
  # ones. Measured before the fix: 6 live artifacts and /first.png still on the
  # page.
  test "replacing an image on an unfiled colorway actually replaces it" do
    home_win!
    assert_unfiled_colorway
    attach_all
    assert_equal 3, Artifact.live.count, "the control — one live artifact per slot before the replace"

    slots.each_index { |i| attach(i, "/second-#{i}.png") }

    assert_equal 3, Artifact.live.count,
                 "the replacement must supersede, not pile up beside what it replaces"
    get content_path(@content.slug)
    assert_match "/second-0.png", response.body,
                 "the image the operator just attached must be the one on the page"
    assert_no_match(/\/x\.png/, response.body,
                    "the superseded image must be gone from the page")
  end

  # The page told the operator "no look" for a person whose look it had just
  # filed — on the one screen whose job is trust about assets.
  test "[component] the slot names the look rather than claiming there is none" do
    home_win!
    assert_unfiled_colorway
    attach_all

    get content_path(@content.slug)

    assert_no_match(/no look/, response.body)
    assert_match "Joe Burrow: Primary", response.body
  end

  # THE LATENT HALF, and the reason nil is not merely cosmetic. A null row is
  # findable only while the person has NO default. Giving them their first look
  # later re-points every read and strands every artifact already on file for
  # them — silently, with no error and nothing to grep for.
  test "a look created later does not strand the artifacts already filed" do
    Appearance.delete_all
    # `Appearance.delete_all` leaves the person pointing at the row it deleted,
    # and `become_default_if_first` only fires on a BLANK pointer — so without
    # this the new look below never becomes the default, the read never
    # re-points, and the test passes on the broken tree for the wrong reason.
    Person.where(slug: [@burrow.slug, @chase.slug]).update_all(default_appearance_slug: nil)
    home_win!
    assert_nil Person.find_by(slug: @burrow.slug).default_appearance_slug,
               "the control — the cast must start with no looks and no default pointer"

    attach_all
    assert_equal [:reuse, :reuse, :reuse], slots.map(&:decision), "the control — filed and findable"

    Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals white", colorway: "white")
    Appearance.create!(person_slug: @chase.slug,  descriptor: "Bengals white", colorway: "white")
    assert Person.find_by(slug: @burrow.slug).default_appearance,
           "the control — the new look must have become the default, or the read never re-points"

    assert_equal [:reuse, :reuse, :reuse], slots.map(&:decision),
                 "a new look must not strand artifacts already filed for this cast"
  end

  # AND THE SUPERSEDE SURVIVES THE REFUSAL — the regression this section caused.
  #
  # `Slot#reuse?` gated TWO things: the badge on the card and the retire in
  # ContentsController#attach_artifact. Moving the lookless + named-colorway
  # population from :reuse to :reskin moved it out of BOTH, so the operator
  # clicked Replace and the page kept rendering the old picture — two live
  # artifacts in one reuse cell, and `decide`'s cast lookup returns whichever
  # the database hands back first.
  #
  # That is worse than the defect above: a wrong LABEL over the right picture
  # became the wrong PICTURE, which is the mitigation the label defect leaned
  # on. Zero recorded appearances is every person until their first look is
  # filed, so this is the common path.
  test "[integration] replacing a lookless artifact under a named colorway still supersedes" do
    bare = Person.create!(first_name: "Bare", last_name: "Look", athlete: true)
    @content.update!(qb_player_slug: bare.slug, skill_player_slug: nil, colorway: "black")
    i = index_of("character_sheet")

    attach(i, "/first.png")
    assert_equal 1, Artifact.live.count, "the control — the first attach filed exactly one artifact"

    attach(i, "/second.png")

    assert_equal 1, Artifact.live.where(kind: "character_sheet").count,
                 "the new image takes the same reuse key as the old one, so leaving both live " \
                 "puts two artifacts in one cell and the lookup returns an arbitrary winner"
    assert_equal 1, Artifact.where(kind: "character_sheet").where.not(retired_at: nil).count,
                 "supersede, not delete — the replaced image stays as the record of what was published"

    get content_path(@content.slug)

    assert_match "/second.png", response.body,
                 "the operator clicked Replace; the gate must show the image they just attached"
    assert_no_match(%r{/first\.png}, response.body,
                    "the superseded image must be gone from the card, not merely outranked")
  end

  # AND THE GUARD ON THAT SUPERSEDE — why it cannot key off the refusal itself.
  #
  # Artifact#subject_key reads ArtifactSubject#effective_appearance, which FALLS
  # BACK to the person's default. So "the request could not resolve a look" says
  # nothing whatever about whether the artifact on file HAS one. Retire on the
  # refusal — or on any comparison that reads the request's raw nil against a
  # key that falls back — and a recorded white jersey dies in order to file a
  # black picture, which is the asset this screen exists to preserve.
  test "[integration] a recorded look is not superseded by a colorway it cannot satisfy" do
    @content.update!(skill_player_slug: nil, colorway: "white")
    i = index_of("character_sheet")
    attach(i, "/white.png")
    white = Artifact.live.sole
    assert_equal appearances_for(@burrow, "white").slug, white.subjects.sole.appearance_slug,
                 "the control — this artifact's look is RECORDED, not merely inferred"

    post set_colorway_content_path(@content.slug), params: { colorway: "black" }
    assert_not slots[index_of("character_sheet")].reuse?,
               "the control — this must not be a reuse, or the retire below is never reached. " \
               "NOT a proof that the refusal fired: Burrow's white look is RECORDED, so the keys " \
               "differ (`burrow@` vs `burrow@<white>`) and this stays green with the refusal " \
               "deleted. Measured. The assertion that bites here is the retired_at one below"

    attach(index_of("character_sheet"), "/black.png")

    assert white.reload.retired_at.nil?,
           "the request resolved to nothing; the artifact on file is a recorded white jersey. " \
           "Superseding it here destroys the asset the next white game reuses"
    assert_equal 2, Artifact.live.count
  end

  # --- the wiring blockers a review found ---------------------------------

  # The gate was unreachable in production: nothing wrote the cast, so
  # ArtifactPlan#cast was always empty, slots was always [], and approve always
  # refused — while the workflow sat in the operator's dropdown.
  test "an operator can set the cast through the edit form" do
    blank = Content.create!(title: "No cast yet", workflow: "rapper_replace", stage: "idea")

    patch content_path(blank.slug), params: { content: {
      qb_player_slug: @burrow.slug, skill_player_slug: @chase.slug, colorway: "white"
    } }

    blank.reload
    assert_equal @burrow.slug, blank.qb_player_slug
    assert_equal @chase.slug, blank.skill_player_slug
    assert_equal 3, Content::ArtifactPlan.new(blank).slots.length,
                 "a content with a cast must produce slots — otherwise the gate can never open"
  end

  # Adding :show drew GET /people/:slug, which swallowed the literal
  # /people/search and 404'd the person picker in news/edit and people/merge.
  test "the people search route is not shadowed by the person page" do
    assert_equal({ controller: "people", action: "search" },
                 Rails.application.routes.recognize_path("/people/search"))
    assert_equal({ controller: "people", action: "show", slug: "joe-burrow" },
                 Rails.application.routes.recognize_path("/people/joe-burrow"))
  end

  test "the person search endpoint answers" do
    get search_people_path, params: { q: "Burrow" }

    assert_response :success
    assert_includes JSON.parse(response.body).map { |p| p["slug"] }, @burrow.slug
  end
end
