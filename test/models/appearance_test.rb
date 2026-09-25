require "test_helper"

# [unit] Looks, defaults, and the reuse key.
#
# The simplification this encodes: every person gets a DEFAULT look the moment
# their first one is created, so the common path never names an appearance at
# all. A variant — Burrow in a suit rather than a jersey — is an explicit later
# choice, not something the pipeline has to reason about every time.
class AppearanceTest < ActiveSupport::TestCase
  setup do
    Artifact.delete_all
    Appearance.delete_all
    @burrow = Person.create!(first_name: "Joe", last_name: "Burrow", athlete: true)
    @chase  = Person.create!(first_name: "JaMarr", last_name: "Chase", athlete: true)
  end

  test "the first look created becomes the default" do
    look = Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals white")

    assert_equal look.slug, @burrow.reload.default_appearance_slug
    assert look.default?
  end

  # Otherwise every lookup would have to special-case "has looks but no default".
  test "a second look does not steal the default" do
    first  = Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals white")
    second = Appearance.create!(person_slug: @burrow.slug, descriptor: "Navy suit")

    assert_equal first.slug, @burrow.reload.default_appearance_slug
    assert_not second.default?
  end

  test "the default can be moved deliberately" do
    Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals white")
    suit = Appearance.create!(person_slug: @burrow.slug, descriptor: "Navy suit")

    suit.make_default!

    assert suit.reload.default?
    assert_equal suit.slug, @burrow.reload.default_appearance_slug
  end

  test "colorway is normalised so casing cannot fork an identity" do
    look = Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals white", colorway: "  WHITE ")
    assert_equal "white", look.colorway
  end

  test "one live look per descriptor per person" do
    Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals white")

    assert_raises ActiveRecord::RecordNotUnique do
      Appearance.new(slug: "dupe", person_slug: @burrow.slug, descriptor: "Bengals white").save!(validate: false)
    end
  end

  # An athlete's physical description comes free off the Athlete record; anyone
  # with no role record has only the notes, which is the whole reason the notes
  # live on the LOOK rather than on the person.
  test "the generation brief folds in athlete data when there is any" do
    Athlete.create!(person_slug: @burrow.slug, sport: "football", build: "6ft4 athletic", hair_description: "short brown")
    look = Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals white")

    brief = look.generation_brief
    assert_match "Bengals white", brief
    assert_match "6ft4 athletic", brief
    assert_match "short brown", brief
  end

  test "a person with no athlete record falls back to the look's notes" do
    carrey = Person.create!(first_name: "Jim", last_name: "Carrey")
    look = Appearance.create!(person_slug: carrey.slug, descriptor: "1994 Ace Ventura",
                              generation_notes: "Hawaiian shirt, swept-up hair.")

    assert_match "Hawaiian shirt", look.generation_brief
  end

  # --- the look an attach files ------------------------------------------
  #
  # An attach used to file `nil` whenever the content named a colorway the
  # person had no look in, which put the row under "no look" while every read
  # resolves nil to the person's DEFAULT. The row could then never be found by
  # the lookup that created it.

  test "a colorway with no look on file gets one filed for it" do
    assert_nil @burrow.appearances.live.find_by(colorway: "primary"),
               "the control — Burrow must have no primary look, or this proves nothing"

    look = Appearance.file_for_colorway!(person_slug: @burrow.slug, colorway: "primary")

    assert_equal "primary", look.colorway
    assert_equal "Primary", look.descriptor
    assert_equal [look.slug], @burrow.appearances.live.pluck(:slug)
  end

  # Every upload runs this. Filing a second look per attach would turn the model
  # library into a pile.
  test "filing the same colorway twice returns the look already on file" do
    first  = Appearance.file_for_colorway!(person_slug: @burrow.slug, colorway: "primary")
    second = Appearance.file_for_colorway!(person_slug: @burrow.slug, colorway: "primary")

    assert_equal first.slug, second.slug
    assert_equal 1, @burrow.appearances.count
  end

  test "an operator's own look in that colorway is used rather than a new one" do
    mine = Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals black", colorway: "black")

    assert_equal mine.slug, Appearance.file_for_colorway!(person_slug: @burrow.slug, colorway: "  BLACK ").slug
    assert_equal 1, @burrow.appearances.count
  end

  # Nothing names a colorway, so there is nothing to file. nil then means "no
  # look was named AND the person has none" — the one state in which the read's
  # nil fallback agrees with the row.
  test "no colorway named files nothing" do
    assert_nil Appearance.file_for_colorway!(person_slug: @burrow.slug, colorway: nil)
    assert_nil Appearance.file_for_colorway!(person_slug: @burrow.slug, colorway: "   ")
    assert_equal 0, Appearance.count
  end

  # The live-descriptor index would otherwise raise RecordNotUnique mid-attach
  # and fail the upload over a name collision.
  test "a descriptor already taken does not fail the filing" do
    Appearance.create!(person_slug: @burrow.slug, descriptor: "Primary", colorway: "black")

    look = Appearance.file_for_colorway!(person_slug: @burrow.slug, colorway: "primary")

    assert_equal "primary", look.colorway
    assert_equal "Primary 2", look.descriptor
    assert_equal 2, @burrow.appearances.live.count
  end

  # Retiring a look was a decision; filing reruns it rather than reviving it.
  test "a retired look in that colorway is not revived" do
    retired = Appearance.create!(person_slug: @burrow.slug, descriptor: "Primary", colorway: "primary")
    retired.update!(retired_at: Time.current)

    look = Appearance.file_for_colorway!(person_slug: @burrow.slug, colorway: "primary")

    assert_not_equal retired.slug, look.slug
    assert_equal "Primary", look.descriptor, "the retired name is free again — the index only binds live looks"
  end

  # --- the lifecycle of the DEFAULT pointer -------------------------------
  #
  # `people.default_appearance_slug` is a plain string column with no foreign
  # key, and exactly ONE callback writes it. That callback is an after_CREATE,
  # so every transition that is not a create — a look destroyed, a look handed
  # to another person by a merge — used to leave the pointer describing a world
  # that is no longer there.
  #
  # This is not a hypothetical. A test in PR 1566 passed on a BROKEN tree
  # because `Appearance.delete_all` in its setup left the pointer aimed at a
  # deleted row, so the "first look becomes the default" guarantee — which only
  # fires on a BLANK pointer — never fired and the read never re-pointed. Each
  # test below therefore asserts its CONTROL first: the pointer resolves before
  # the act, so a red is the defect rather than the setup.

  test "destroying the default look re-points it at a remaining live look" do
    first  = Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals white")
    second = Appearance.create!(person_slug: @burrow.slug, descriptor: "Navy suit")

    assert_equal first.slug, @burrow.reload.default_appearance_slug,
                 "the control — the default must point at the first look before we destroy it"
    assert_not_nil @burrow.default_appearance, "the control — and it must RESOLVE before we destroy it"

    first.destroy!

    @burrow.reload
    assert_equal second.slug, @burrow.default_appearance_slug,
                 "the surviving look should have taken the slot"
    assert_not_nil @burrow.default_appearance
  end

  test "destroying a person's only look frees the slot for the next one" do
    only = Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals white")
    assert_equal only.slug, @burrow.reload.default_appearance_slug, "the control"

    only.destroy!

    assert_nil @burrow.reload.default_appearance_slug,
               "a pointer left aimed at the deleted row is what freezes the person forever"

    replacement = Appearance.create!(person_slug: @burrow.slug, descriptor: "Navy suit")
    assert_equal replacement.slug, @burrow.reload.default_appearance_slug,
                 "become_default_if_first guards on a BLANK pointer, so this only works once the slot is free"
  end

  # The invariant the app claims in prose, stated as a test. Before this the
  # state below was permanent and had nothing to grep for.
  test "a person with live looks always resolves a default" do
    first  = Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals white")
    second = Appearance.create!(person_slug: @burrow.slug, descriptor: "Navy suit")
    assert_not_nil @burrow.reload.default_appearance, "the control"

    first.destroy!
    Appearance.create!(person_slug: @burrow.slug, descriptor: "Practice jersey")

    @burrow.reload
    assert_operator @burrow.appearances.live.count, :>, 0
    assert_not_nil @burrow.default_appearance,
                   "live looks and no resolvable default is the state every read has to special-case"
  end

  # Destroying someone ELSE's look must not disturb this person's pointer.
  test "destroying another person's look leaves this one's default alone" do
    mine   = Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals white")
    theirs = Appearance.create!(person_slug: @chase.slug, descriptor: "Bengals black")
    assert_equal mine.slug, @burrow.reload.default_appearance_slug, "the control"

    theirs.destroy!

    assert_equal mine.slug, @burrow.reload.default_appearance_slug
  end

  # --- what the pointer must NOT do ---------------------------------------
  #
  # Each of these was written because a mutation survived: the behaviour was
  # real and load-bearing, and nothing in the suite would have noticed it going.

  # Resolving must not overrule a deliberate choice. Without the keep-a-valid-
  # pointer branch, the next look created or destroyed drags the default back to
  # the oldest and silently undoes "Make default".
  test "a deliberately moved default survives the next look" do
    Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals white")
    suit = Appearance.create!(person_slug: @burrow.slug, descriptor: "Navy suit")
    suit.make_default!
    assert_equal suit.slug, @burrow.reload.default_appearance_slug, "the control"

    Appearance.create!(person_slug: @burrow.slug, descriptor: "Practice jersey")

    assert_equal suit.slug, @burrow.reload.default_appearance_slug,
                 "resolving must keep a valid pointer, not re-pick the oldest look"
  end

  # A pointer at a RETIRED look resolves through belongs_to perfectly well, so
  # nothing raises — Content::ArtifactPlan#appearance_for just hands the
  # pipeline a look that was deliberately taken out of service.
  test "a retired look does not keep the default slot" do
    first  = Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals white")
    second = Appearance.create!(person_slug: @burrow.slug, descriptor: "Navy suit")
    assert_equal first.slug, @burrow.reload.default_appearance_slug, "the control"

    first.update!(retired_at: Time.current)
    Appearance.create!(person_slug: @burrow.slug, descriptor: "Practice jersey")

    assert_equal second.slug, @burrow.reload.default_appearance_slug,
                 "the default must name a LIVE look"
    assert_includes @burrow.appearances.live.pluck(:slug), @burrow.default_appearance_slug
  end

  # Re-pointing takes the OLDEST survivor, which is the same rule
  # become_default_if_first encodes — the person's earliest look keeps priority
  # rather than whichever one happened to be added last.
  test "re-pointing takes the oldest surviving look" do
    first  = Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals white")
    second = Appearance.create!(person_slug: @burrow.slug, descriptor: "Navy suit")
    third  = Appearance.create!(person_slug: @burrow.slug, descriptor: "Practice jersey")
    assert_equal first.slug, @burrow.reload.default_appearance_slug, "the control"

    first.destroy!

    assert_equal second.slug, @burrow.reload.default_appearance_slug,
                 "the oldest survivor takes the slot, not the newest look"
    assert_not_equal third.slug, @burrow.reload.default_appearance_slug
  end

  # The pointer is a bare string column with no foreign key, so "the owner holds
  # it" is a convention rather than a guarantee. Releasing by COLUMN rather than
  # through #person is what makes the release complete.
  test "a destroyed look releases every pointer aimed at it" do
    look = Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals white")
    @chase.update_columns(default_appearance_slug: look.slug)
    assert_equal look.slug, @chase.reload.default_appearance_slug, "the control"

    look.destroy!

    assert_nil @chase.reload.default_appearance_slug,
               "a pointer held by someone else dangles just as badly"
  end

  # THE VACUITY TRAP THIS SEAM PRODUCES, pinned as a test.
  #
  # A test in PR 1566 passed on a broken tree because `Appearance.delete_all` in
  # its setup left the pointer aimed at a deleted row: the old guard read a
  # DANGLING pointer as "already has a default" and never stamped the later
  # look, so the read never re-pointed and the assertion passed for the wrong
  # reason. Resolving rather than testing for blank heals that on the next
  # create, whatever removed the row.
  test "a look created after a raw delete takes the orphaned slot" do
    Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals white")
    Appearance.delete_all # no callbacks — exactly what the vacuous setup did
    assert @burrow.reload.default_appearance_slug.present?, "the control — the pointer is dangling"
    assert_nil @burrow.default_appearance, "the control — and it resolves to nothing"

    replacement = Appearance.create!(person_slug: @burrow.slug, descriptor: "Navy suit")

    assert_equal replacement.slug, @burrow.reload.default_appearance_slug
    assert_not_nil @burrow.default_appearance
  end

  # REGRESSION. `colorway` is free text — the jersey field at the inspection
  # gate takes whatever the operator types — and the descriptor was built as
  # `colorway.titleize`, which is "" for input that is all punctuation. That
  # failed the descriptor presence validation, so `create!` raised mid-attach
  # and the operator got an error page. Before the look was filed at all, the
  # same input wrote a nil appearance and the attach simply succeeded, so this
  # was a live regression, not a pre-existing wart.
  test "a colorway whose titleize is empty still files a usable look" do
    assert_equal "", "_".titleize,
                 "the control — if titleize stops returning \"\" here, this test no longer reproduces anything"

    look = Appearance.file_for_colorway!(person_slug: @burrow.slug, colorway: "_")

    assert_predicate look, :persisted?
    assert_equal "_", look.colorway
    assert_predicate look.descriptor, :present?
  end

  # --- the Higgsfield character identity ----------------------------------
  #
  # Measured 2026-09-24 by creating a real reference and polling it to rest:
  # not_ready -> queued -> in_progress -> completed. The create answers
  # `not_ready`, so an identity is NEVER usable at the moment it is recorded,
  # and every pin costs money.

  test "a look with no identity is neither ready nor pending" do
    look = Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals white")

    assert_not look.higgsfield_reference_ready?
    assert_not look.higgsfield_reference_pending?
  end

  test "only the observed success state unlocks a pin" do
    look = Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals white",
                              higgsfield_reference_id: "1af15765-27b3-461a-8804-b2de098c72c3",
                              higgsfield_reference_status: "completed")

    assert look.higgsfield_reference_ready?
    assert_not look.higgsfield_reference_pending?
  end

  test "every state on the way there reads as pending, not ready" do
    look = Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals white",
                              higgsfield_reference_id: "1af15765-27b3-461a-8804-b2de098c72c3")

    %w[not_ready queued in_progress].each do |state|
      look.update!(higgsfield_reference_status: state)

      assert look.higgsfield_reference_pending?, "#{state} is on the way"
      assert_not look.higgsfield_reference_ready?, "#{state} must not unlock a paid generation"
    end
  end

  # The tempting inverse — "not one of the pending words" — reads every status we
  # have never seen, including whatever the API says when a reference FAILS, as
  # ready.
  test "a state nobody has seen is not read as ready" do
    look = Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals white",
                              higgsfield_reference_id: "1af15765-27b3-461a-8804-b2de098c72c3",
                              higgsfield_reference_status: "exploded")

    assert_not look.higgsfield_reference_ready?
    assert_not look.higgsfield_reference_pending?
  end

  # A status with no id is a half-written row, and the id is what a generation
  # would actually send.
  test "a status without an id cannot be ready" do
    look = Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals white",
                              higgsfield_reference_status: "completed")

    assert_not look.higgsfield_reference_ready?
  end

  # One vendor identity belongs to exactly one look: sharing an id would mean an
  # edit to one silently repoints the other.
  test "two looks cannot claim the same identity" do
    Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals white",
                       higgsfield_reference_id: "1af15765-27b3-461a-8804-b2de098c72c3")

    assert_raises ActiveRecord::RecordNotUnique do
      Appearance.create!(person_slug: @chase.slug, descriptor: "Bengals white",
                         higgsfield_reference_id: "1af15765-27b3-461a-8804-b2de098c72c3")
    end
  end

  # The partial index is what lets the overwhelming majority of looks — which
  # have no identity — coexist on NULL.
  test "looks without an identity do not collide on null" do
    Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals white")

    assert_nothing_raised do
      Appearance.create!(person_slug: @chase.slug, descriptor: "Bengals white")
    end
  end
end
