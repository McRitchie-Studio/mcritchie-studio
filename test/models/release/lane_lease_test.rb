# frozen_string_literal: true

require "test_helper"

# [unit] Release::LaneLease: the sentences that say who holds the release lane and
# what a production grant covers. The grant record carries the member set at the
# moment it was given and the policy; the sentences count and name later joiners.
class Release::LaneLeaseTest < ActiveSupport::TestCase
  NOW = Time.utc(2026, 10, 8, 1, 30, 0)

  setup do
    Release.delete_all
    ReleaseConductorClaim.delete_all
    SessionMascot.delete_all
    @rel = Release.open!
  end

  def member!(label)
    task = Task.create!(title: "lane lease #{label} member task", stage: "reviewed")
    @rel.add(task)
    task
  end

  def request!(mode: "timed", ends_at: NOW + 30.minutes, at: NOW)
    metadata = { "mode" => mode }
    metadata.merge!("window_ends_at" => ends_at.utc.iso8601, "window_minutes" => 30) if mode == "timed"
    @rel.record_event!(step: "ship_authorized", status: "started", source: "conductor", actor: "steffon",
                       occurred_at: at, metadata: metadata)
  end

  def approve!(at: NOW + 5.minutes)
    travel_to(at) { @rel.grant_ship_authorization!(actor: users(:alex).email, source: "web", approver: users(:alex)) }
  end

  # A `ship_authorized completed` row as a caller writes it: no approver keyword.
  # An api or agent completion owes usage (EventUsage), so those rows carry it.
  USAGE = { model: "test-model", tokens_in: 1, tokens_out: 1, cost: 0 }.freeze

  def answer!(at: NOW + 2.minutes, **attrs)
    attrs = USAGE.merge(attrs) if %w[api agent].include?(attrs[:source])
    travel_to(at) { @rel.record_event!(step: "ship_authorized", status: "completed", **attrs) }
  end

  def sentences(now: NOW + 10.minutes)
    Release::LaneLease.grant_sentences(@rel.reload, now: now)
  end

  def lines(now: NOW + 10.minutes)
    Release::LaneLease.grant_sentences(@rel.reload, now: now).map(&:to_s)
  end

  # --- the grant record ---------------------------------------------------------

  test "[unit] the grant record carries the member set at grant time and the policy" do
    first = member!("first")
    second = member!("second")
    request!
    grant = approve!

    scope = grant.reload.metadata["scope"]
    assert_equal "release_at_ship", scope["policy"]
    assert_equal [first.slug, second.slug].sort, scope["member_slugs"].sort
    assert_equal "web", grant.metadata["granted_via"]
  end

  test "[unit] the member set on the record is the release's own, never a caller's" do
    real = member!("real")
    request!(mode: "auto")
    event = @rel.record_event!(step: "ship_authorized", status: "completed", source: "conductor",
                               metadata: { "mode" => "auto", "granted_via" => "auto",
                                           "scope" => { "policy" => "members_only", "member_slugs" => ["forged"] } })

    assert_equal({ "policy" => "release_at_ship", "member_slugs" => [real.slug] }, event.reload.metadata["scope"])
  end

  test "[unit] control: only an answer carries a scope; the request and other steps do not" do
    member!("only")
    asked = request!
    other = @rel.record_event!(step: "deploy_prod", status: "completed", source: "conductor", metadata: {})

    assert_nil asked.metadata["scope"]
    assert_nil other.metadata["scope"]
  end

  test "[unit] ship's own completion after the Approve keeps the set recorded at the tap" do
    first = member!("first")
    ends_at = NOW + 30.minutes
    request!(ends_at: ends_at)
    grant = approve!
    late = member!("late")
    stamp = @rel.record_event!(step: "ship_authorized", status: "completed", source: "conductor",
                               idempotency_key: "#{@rel.slug}:ship_authorized:completed:#{ends_at.utc.iso8601}")

    assert_equal grant.id, stamp.id
    assert_equal [first.slug], stamp.reload.metadata["scope"]["member_slugs"]
    refute_includes stamp.metadata["scope"]["member_slugs"], late.slug
  end

  # --- the grant sentences ------------------------------------------------------

  test "[unit] an active release with no request says none was asked for" do
    assert_equal ["No production approval has been asked for."], lines
  end

  test "[unit] an open timed request says it waits on the owner and when the window closes" do
    request!
    assert_equal ["Production approval is waiting on the owner: the window closes at Oct 8, 02:00 UTC."], lines
  end

  test "[unit] a window past its end with no answer says it closed" do
    request!
    assert_equal ["The production window closed at Oct 8, 02:00 UTC with no answer."], lines(now: NOW + 31.minutes)
  end

  test "[unit] an approval states who, when, the mode and what it covers" do
    member!("first")
    member!("second")
    request!
    approve!

    assert_equal [
      "Approved by Alex McRitchie at Oct 8, 01:35 UTC, timed mode.",
      "Covers every task on this release when it ships: 2 at approval, 2 now."
    ], lines
  end

  test "[unit] the summary counts later joiners and names them" do
    member!("first")
    request!
    approve!
    joined = [member!("second"), member!("third")]

    out = lines
    assert_equal "Covers every task on this release when it ships: 1 at approval, 3 now.", out[1]
    assert_equal "Joined after approval: #{joined.map(&:slug).join(', ')}.", out[2]
    assert_equal 3, out.size
  end

  test "[unit] control: with no later joiner the sentence names none" do
    member!("first")
    request!
    approve!

    assert(lines.none? { |line| line.start_with?("Joined after") })
  end

  test "[unit] a member that left after the approval is named" do
    stays = member!("stays")
    leaves = member!("leaves")
    request!
    approve!
    leaves.update!(release_slug: nil)

    out = lines
    assert_equal "Covers every task on this release when it ships: 2 at approval, 1 now.", out[1]
    assert_equal "Left after approval: #{leaves.slug}.", out[2]
    assert_includes Release::LaneLease.scope_for(@rel)["member_slugs"], stays.slug
  end

  test "[unit] a grant recorded without a member set says the set is not recorded" do
    member!("first")
    request!
    grant = approve!
    grant.update_columns(metadata: grant.metadata.except("scope"))

    assert_equal "Covers every task on this release when it ships: member set at approval not recorded, 1 now.", lines[1]
    assert_equal 2, lines.size
  end

  test "[unit] a shipped release states the grant in the past tense" do
    member!("first")
    request!
    approve!
    member!("second")
    @rel.update_columns(state: "shipped", shipped_at: NOW + 20.minutes)

    assert_equal "Covered every task on this release when it shipped: 1 at approval, 2 at ship.", lines[1]
  end

  test "[unit] a lapse is stated as no approval, never as one" do
    ends_at = NOW + 30.minutes
    request!(ends_at: ends_at)
    answer!(at: ends_at, source: "conductor", actor: "steffon",
            metadata: { "mode" => "timed", "lapsed" => true, "granted_via" => "window-lapse" })

    out = lines(now: ends_at + 1.minute)
    assert_equal "No approval was given: the window lapsed at Oct 8, 02:00 UTC and the ship proceeded on green, timed mode.", out.first
    refute @rel.reload.ship_authorization_granted?
    assert(out.none? { |line| line.start_with?("Approved") })
  end

  # --- who approved: only the web Approve's marker names a person -----------------

  APPROVER_WORDS = /Approved by|Confirmed/

  test "[unit] the web Approve's marker is the signed-in admin, and the sentence names that user" do
    request!
    grant = approve!

    marker = grant.reload.metadata["owner_grant"]
    assert_equal users(:alex).id, marker["user_id"]
    assert_equal %w[at user_id user_slug], marker.keys.sort
    assert_equal "2026-10-08T01:35:00Z", marker["at"]
    assert_equal "Approved by Alex McRitchie at Oct 8, 01:35 UTC, timed mode.", lines.first
    assert_equal :success, sentences.first.tone
  end

  test "[unit] the approver's name is the marker's user, never the row's actor" do
    request!
    travel_to(NOW + 5.minutes) do
      @rel.grant_ship_authorization!(actor: "somebody-else@example.com", source: "web", approver: users(:alex))
    end

    assert_equal "Approved by Alex McRitchie at Oct 8, 01:35 UTC, timed mode.", lines.first
  end

  test "[unit] ask mode under --yes: the row ship records reads as a CLI record, not a person's confirmation" do
    require Rails.root.join("bin/lib/ship_authority").to_s
    member!("first")
    # bin/release ship --mode ask --yes from an agent shell: `confirm` answers true
    # with no prompt shown, and the actor is ENV["USER"].
    recorder = lambda do |status, metadata|
      travel_to(NOW + (status == "started" ? 0 : 2.minutes)) do
        Release::Conductor.record_event!(release: @rel, step: ShipAuthority::STEP, status: status, actor: "alex",
                                         source: "conductor", metadata: metadata,
                                         idempotency_key: [@rel.slug, ShipAuthority::STEP, status].join(":"))
      end
    end
    result = ShipAuthority.take!(mode: "ask", release_slug: @rel.slug, minutes: 30, recorder: recorder,
                                 reader: ->(**) { }, confirmer: ->(_prompt) { true }, say: ->(_line) { })

    assert_equal :confirmed, result
    assert @rel.reload.ship_authorization_granted?, "authority is recorded exactly as it was"
    assert_equal "confirm", @rel.ship_authorization_grant.metadata["granted_via"]
    assert_equal [
      "Recorded by the conductor CLI in ask mode (run as alex) at Oct 8, 01:32 UTC; no web approval.",
      "Covers every task on this release when it ships: 1 at authorization, 1 now."
    ], lines
    assert_equal :warning, sentences.first.tone
    assert_no_match APPROVER_WORDS, lines.join(" ")
  end

  test "[unit] a row that claims the web, the owner and a web grant, with no marker, names no approver" do
    member!("first")
    request!
    answer!(source: "web", actor: users(:alex).email, metadata: { "granted_via" => "web" })

    assert @rel.reload.ship_authorization_granted?, "the row still grants, as it does today"
    assert_equal [
      "Authorized at Oct 8, 01:32 UTC (timed mode); approver not recorded.",
      "Covers every task on this release when it ships: 1 at authorization, 1 now."
    ], lines
    assert_equal :muted, sentences.first.tone
    assert_no_match APPROVER_WORDS, lines.join(" ")
    refute_includes lines.join(" "), "Alex McRitchie"
  end

  test "[unit] the same row with a lapse flag reads as the lapse" do
    request!
    answer!(source: "web", actor: users(:alex).email, metadata: { "granted_via" => "web", "lapsed" => true })

    refute @rel.reload.ship_authorization_granted?
    assert_equal "No approval was given: the window lapsed at Oct 8, 01:32 UTC and the ship proceeded on green, timed mode.", lines.first
    assert_equal :warning, sentences.first.tone
    assert_no_match APPROVER_WORDS, lines.join(" ")
  end

  test "[unit] a lapse flag reads as the lapse even on a row that carries the marker" do
    request!
    grant = approve!
    grant.update_columns(metadata: grant.metadata.merge("lapsed" => true))

    assert_match(/\ANo approval was given: the window lapsed/, lines.first)
    assert_equal "Covers every task on this release when it ships: 0 at authorization, 0 now.", lines.second
    assert_no_match APPROVER_WORDS, lines.join(" ")
  end

  test "[unit] a caller's own owner_grant is removed from the metadata of every event" do
    forged = { "user_id" => users(:alex).id, "user_slug" => users(:alex).slug, "at" => NOW.iso8601 }
    request!
    answer = answer!(source: "web", actor: users(:alex).email,
                     metadata: { "granted_via" => "web", "owner_grant" => forged })
    shown = lines.first
    symbol = @rel.record_event!(step: "ship_authorized", status: "completed", source: "web",
                                metadata: { owner_grant: forged, note: "kept" })
    other = @rel.record_event!(step: "deploy_prod", status: "completed", source: "conductor",
                               metadata: { "owner_grant" => forged, "note" => "kept" })

    assert_nil answer.reload.metadata["owner_grant"]
    assert_equal "web", answer.metadata["granted_via"], "nothing else of the caller's metadata is touched"
    assert_nil symbol.reload.metadata["owner_grant"]
    assert_equal "kept", symbol.metadata["note"]
    assert_equal({ "note" => "kept" }, other.reload.metadata)
    assert_equal "Authorized at Oct 8, 01:32 UTC (timed mode); approver not recorded.", shown
  end

  test "[unit] the conductor's recorder passes on neither the marker nor the approver keyword" do
    forged = { "user_id" => users(:alex).id, "user_slug" => users(:alex).slug, "at" => NOW.iso8601 }
    request!
    event = travel_to(NOW + 2.minutes) do
      Release::Conductor.record_event!(release: @rel, step: "ship_authorized", status: "completed", source: "conductor",
                                       actor: "alex", owner_grant: users(:alex),
                                       metadata: { "mode" => "timed", "granted_via" => "web", "owner_grant" => forged })
    end

    assert_nil event.reload.metadata["owner_grant"]
    assert_equal "Recorded by the conductor CLI in timed mode (run as alex) at Oct 8, 01:32 UTC; no web approval.", lines.first
  end

  test "[unit] control: the approver keyword takes a saved user and nothing else" do
    request!
    event = @rel.record_event!(step: "ship_authorized", status: "completed", source: "web",
                               owner_grant: { "user_id" => users(:alex).id })
    assert_nil event.reload.metadata["owner_grant"]

    asked = @rel.record_event!(step: "ship_authorized", status: "started", source: "conductor",
                               owner_grant: users(:alex), metadata: { "mode" => "ask" })
    assert_nil asked.reload.metadata["owner_grant"], "only an answer carries the marker"
  end

  test "[unit] auto mode says nobody was asked" do
    request!(mode: "auto")
    answer!(source: "conductor", actor: "alex", metadata: { "mode" => "auto", "granted_via" => "auto" })

    assert_equal "Proceeded on green with no approval asked at Oct 8, 01:32 UTC (auto mode).", lines.first
    assert_equal :warning, sentences.first.tone
  end

  test "[unit] a row through the events API names its recorder as a recorder" do
    request!
    answer!(at: NOW + 3.minutes, source: "api", actor: users(:alex).email, metadata: { "granted_via" => "web" })

    assert_equal "Recorded through the events API by #{users(:alex).email} at Oct 8, 01:33 UTC; no web approval.", lines.first
    assert_equal :warning, sentences.first.tone
    assert_no_match APPROVER_WORDS, lines.join(" ")
    refute_includes lines.join(" "), "Alex McRitchie"
  end

  test "[unit] a recorder with no name reads as unnamed, and a long one is cut" do
    request!
    answer!(source: "script", metadata: {})
    assert_equal "Recorded through the events API by an unnamed caller at Oct 8, 01:32 UTC; no web approval.", lines.first

    answer!(at: NOW + 3.minutes, source: "script", actor: "x" * 200, metadata: {})
    assert_operator lines.first.size, :<, 140
  end

  test "[unit] no row without the marker reads as an approval or in the success tone" do
    request!
    sources = %w[web conductor api agent script]
    vias = ["web", "confirm", "auto", "grant", nil]
    sources.product(vias, [true, false]).each_with_index do |(source, via, lapsed), index|
      metadata = { "granted_via" => via, "lapsed" => lapsed }.compact
      answer!(at: NOW + 2.minutes + index.seconds, source: source, actor: users(:alex).email, metadata: metadata)
      shown = @rel.reload.ship_authorization_grant || @rel.ship_authorization_lapse
      sentence = Release::LaneLease.answer_sentence(shown, "timed")

      assert_no_match APPROVER_WORDS, sentence.to_s, "#{source}/#{via}/#{lapsed}"
      refute_includes sentence.to_s, "Alex McRitchie"
      refute_equal :success, sentence.tone, "#{source}/#{via}/#{lapsed}"
    end
  end

  # --- the holders ----------------------------------------------------------------

  def claim!(role, session:, soul: nil, label: nil, now: NOW)
    ReleaseConductorClaim.acquire(release_slug: @rel.slug, role: role, session: session, nonce: "n-#{role}",
                                  soul: soul, label: label, now: now)
  end

  def holder_lines(now: NOW + 30.seconds)
    travel_to(now) { Release::LaneLease.holders(@rel.slug).values.map { |h| Release::LaneLease.holder_sentence(h).to_s } }
  end

  test "[unit] with no claim, each role says nobody holds it" do
    assert_equal ["Nobody is assembling #{@rel.slug}.", "Nobody is shipping #{@rel.slug}."], holder_lines
  end

  test "[unit] a live holder is named by mascot, soul, session tail and since" do
    Pokemon.create!(dex: 303, name: "Mawile", slug: "mawile", types: %w[steel], generation: 3)
    SessionMascot.create!(session_id: "sess-assembler-9b57", mascot_slug: "mawile")
    claim!("assembler", session: "sess-assembler-9b57", soul: "steffon")
    claim!("deployer", session: "sess-deployer-41cd")

    assert_equal [
      "Mawile (steffon, session …9b57) is assembling #{@rel.slug} since Oct 8, 01:30 UTC.",
      "Session …41cd is shipping #{@rel.slug} since Oct 8, 01:30 UTC."
    ], holder_lines
  end

  test "[unit] a holder sentence never carries the whole session id or the nonce" do
    claim!("assembler", session: "sess-secret-long-id-9b57", soul: "steffon", label: "Snorlax")
    line = holder_lines.first

    assert_includes line, "Snorlax (steffon, session …9b57)"
    refute_includes line, "sess-secret-long-id"
    refute_includes line, "n-assembler"
  end

  test "[unit] a lapsed lease says the claim is free to take" do
    claim!("assembler", session: "sess-gone-aaaa", label: "Snorlax")
    line = holder_lines(now: NOW + 10.minutes).first

    assert_equal "Snorlax (session …aaaa) held the assembler claim on #{@rel.slug} since Oct 8, 01:30 UTC; " \
                 "its lease has lapsed, so the claim is free to take.", line
  end

  test "[unit] the holder descriptor the API serves carries the same sentence" do
    claim!("assembler", session: "sess-assembler-9b57", soul: "steffon", label: "Snorlax")
    info = travel_to(NOW + 30.seconds) { ReleaseConductorClaim.status_for(@rel.slug, "assembler") }

    assert_equal holder_lines.first, info["sentence"]
    assert_equal "steffon", info["soul"]
    assert_equal "Snorlax", info["mascot"]
  end

  test "[unit] a failure building the sentence leaves the holder descriptor served without one" do
    claim!("assembler", session: "sess-assembler-9b57", soul: "steffon", label: "Snorlax")
    original = Release::LaneLease.method(:holder_sentence)
    Release::LaneLease.define_singleton_method(:holder_sentence) { |*| raise NoMethodError, "a bug in the sentence" }

    info = travel_to(NOW + 30.seconds) { ReleaseConductorClaim.status_for(@rel.slug, "assembler") }

    assert_nil info["sentence"]
    assert_nil info["mascot"]
    assert_equal "sess-assembler-9b57", info["session"]
    assert_equal "Snorlax", info["label"]
    assert info["live"]
  ensure
    Release::LaneLease.define_singleton_method(:holder_sentence, original) if original
  end

  test "[unit] the forming claim reads as the next release" do
    ReleaseConductorClaim.acquire(release_slug: ReleaseConductorClaim::FORMING_SLUG, role: "assembler",
                                  session: "sess-forming-77aa", nonce: "n", label: "Onix", now: NOW)
    lines = travel_to(NOW + 30.seconds) { Release::LaneLease.status_lines(nil) }

    assert_equal ["Onix (session …77aa) is assembling the next release since Oct 8, 01:30 UTC."], lines
  end

  test "[unit] status lines are the holder sentences then the grant sentences" do
    member!("first")
    claim!("assembler", session: "sess-assembler-9b57", label: "Snorlax")
    request!
    approve!
    lines = travel_to(NOW + 6.minutes) { Release::LaneLease.status_lines(@rel.reload) }

    assert_equal 4, lines.size
    assert_match(/\ASnorlax \(session …9b57\) held the assembler claim/, lines[0])
    assert_equal "Nobody is shipping #{@rel.slug}.", lines[1]
    assert_match(/\AApproved by Alex McRitchie/, lines[2])
    assert_match(/\ACovers every task on this release when it ships: 1 at approval, 1 now\.\z/, lines[3])
  end
end
