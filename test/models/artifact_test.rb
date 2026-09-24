require "test_helper"

# [unit] The join that removed the two-player ceiling, and the reuse key.
#
# The shape this replaced carried `secondary_player_slug` and capped at two
# people. A three-person cast — the Jim Carrey / George Bush / Joe Burrow case
# Mr. McRitchie named — broke it immediately.
class ArtifactTest < ActiveSupport::TestCase
  setup do
    Artifact.delete_all
    Appearance.delete_all
    @burrow = Person.create!(first_name: "Joe", last_name: "Burrow", athlete: true)
    @chase  = Person.create!(first_name: "JaMarr", last_name: "Chase", athlete: true)
    @carrey = Person.create!(first_name: "Jim", last_name: "Carrey")

    @bw = Appearance.create!(person_slug: @burrow.slug, descriptor: "Bengals white", colorway: "white")
    @cb = Appearance.create!(person_slug: @chase.slug, descriptor: "Bengals black", colorway: "black")
    @ace = Appearance.create!(person_slug: @carrey.slug, descriptor: "1994 Ace Ventura")
  end

  def artifact_for(pairs, kind:, approved: true)
    a = Artifact.create!(kind: kind, image_url: "/x.png",
                         approved_at: approved ? Time.current : nil)
    pairs.each_with_index do |(person, look), i|
      a.subjects.create!(person_slug: person.slug, appearance_slug: look&.slug, ordinal: i + 1)
    end
    a
  end

  test "a three person cast is three rows, not a third column" do
    a = artifact_for([[@carrey, @ace], [@burrow, @bw], [@chase, @cb]], kind: "group")

    assert_equal 3, a.subjects.count
    assert_equal "Jim Carrey + Joe Burrow + JaMarr Chase", a.cast_label
  end

  # The point of putting appearance on the SUBJECT: a mixed cast carries
  # different looks in one frame, which an artifact-level uniform cannot express.
  test "each subject carries its own look" do
    a = artifact_for([[@burrow, @bw], [@chase, @cb]], kind: "pair")

    looks = a.subjects.ordered.map { |s| s.effective_appearance.descriptor }
    assert_equal ["Bengals white", "Bengals black"], looks
  end

  test "a subject with no explicit look falls back to the person's default" do
    a = artifact_for([[@burrow, nil]], kind: "character_sheet")

    assert_equal @bw.slug, a.subjects.first.effective_appearance.slug
  end

  test "the reuse key is the set of person-and-look pairs" do
    a = artifact_for([[@burrow, @bw], [@chase, @cb]], kind: "pair")

    assert_includes a.subject_key, "#{@burrow.slug}@#{@bw.slug}"
    assert_includes a.subject_key, "#{@chase.slug}@#{@cb.slug}"
  end

  test "matching finds an artifact by its exact cast and looks" do
    artifact_for([[@burrow, @bw], [@chase, @cb]], kind: "pair")

    found = Artifact.matching([[@burrow.slug, @bw.slug], [@chase.slug, @cb.slug]], kind: "pair")
    assert found, "the same cast in the same looks should match"
  end

  # Same people, one wearing a different jersey, is a DIFFERENT asset — the
  # whole reason colorway is part of identity rather than a detail.
  test "a different look on one subject is a different asset" do
    artifact_for([[@burrow, @bw], [@chase, @cb]], kind: "pair")
    cw = Appearance.create!(person_slug: @chase.slug, descriptor: "Bengals white", colorway: "white")

    found = Artifact.matching([[@burrow.slug, @bw.slug], [@chase.slug, cw.slug]], kind: "pair")
    assert_nil found
  end

  test "an unapproved artifact is not offered for reuse" do
    artifact_for([[@burrow, @bw]], kind: "character_sheet", approved: false)

    assert_nil Artifact.matching([[@burrow.slug, @bw.slug]], kind: "character_sheet")
  end

  test "a retired artifact is not offered for reuse" do
    a = artifact_for([[@burrow, @bw]], kind: "character_sheet")
    a.retire!

    assert_nil Artifact.matching([[@burrow.slug, @bw.slug]], kind: "character_sheet")
  end

  test "one subject row per person per artifact" do
    a = artifact_for([[@burrow, @bw]], kind: "character_sheet")

    assert_raises ActiveRecord::RecordNotUnique do
      a.subjects.create!(person_slug: @burrow.slug, appearance_slug: @bw.slug, ordinal: 2)
    end
  end

  test "a person reads back every artifact they appear in, shared ones included" do
    artifact_for([[@burrow, @bw]], kind: "character_sheet")
    artifact_for([[@burrow, @bw], [@chase, @cb]], kind: "pair")

    count = Artifact.joins(:subjects).where(artifact_subjects: { person_slug: @burrow.slug }).distinct.count
    assert_equal 2, count
  end

  # --- an artifact whose cast goes away -----------------------------------
  #
  # `Person has_many :artifact_subjects, dependent: :destroy`, so destroying a
  # person takes their cast rows with them and a solo character sheet outlives
  # the only person in it. It stays `live`, its cast label renders empty, and
  # its reuse key is the empty string — an image of NOBODY, still on offer.

  test "an artifact that loses its last subject is retired" do
    a = artifact_for([[@carrey, @ace]], kind: "character_sheet")
    assert_not a.retired?, "the control — it must be live before the cast goes"
    assert_equal 1, a.subjects.count, "the control"

    @carrey.destroy!

    a.reload
    assert_equal 0, a.subjects.count
    assert a.retired?, "an artifact depicting nobody must not stay on offer"
    assert_nil Artifact.live.find_by(slug: a.slug)
  end

  # Losing ONE of several is not losing the cast. Retiring there would throw
  # away a real image over a partial change.
  test "an artifact that keeps a subject is left live" do
    a = artifact_for([[@burrow, @bw], [@chase, @cb]], kind: "pair")
    assert_not a.retired?, "the control"

    @chase.destroy!

    a.reload
    assert_equal 1, a.subjects.count
    assert_not a.retired?
  end

  # The retire hook must not fire while the artifact ITSELF is being destroyed.
  # Its subjects go first, so the last one finds an empty cast and would retire
  # the very row on its way out. Nothing RAISES if it does — Rails will happily
  # run that UPDATE inside the destroy — which is exactly why this has to be
  # measured at the SQL rather than asserted at the outcome.
  test "destroying an artifact issues no retire write on the way out" do
    a = artifact_for([[@burrow, @bw]], kind: "character_sheet")
    slug = a.slug
    writes = []
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      writes << payload[:sql] if payload[:sql].to_s.match?(/\AUPDATE "artifacts"/i)
    end

    begin
      assert_nothing_raised { a.destroy! }
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    assert_empty writes, "the artifact is going away; retiring it first is a wasted write on a doomed row"
    assert_nil Artifact.find_by(slug: slug)
    assert_equal 0, ArtifactSubject.where(artifact_slug: slug).count
  end

  # The control for the test above: the same subscriber DOES see a write when
  # the artifact is meant to be retired, so an empty `writes` proves the guard
  # rather than proving the subscriber never fires.
  test "the retire write is visible to the same probe when it should happen" do
    a = artifact_for([[@carrey, @ace]], kind: "character_sheet")
    writes = []
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      writes << payload[:sql] if payload[:sql].to_s.match?(/\AUPDATE "artifacts"/i)
    end

    begin
      @carrey.destroy!
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    assert_not_empty writes, "losing the last subject must retire the artifact"
    assert a.reload.retired?
  end
end
