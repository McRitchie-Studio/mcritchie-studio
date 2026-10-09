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
    assert_equal %w[at sig user_id user_slug], marker.keys.sort
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

  # --- the marker counts only when its signature verifies for its own row ---------

  LEGACY = "Authorized at Oct 8, 01:32 UTC (timed mode); approver not recorded."
  GRANT_KEY = "grant-row-key"

  # A `ship_authorized completed` row stored as code with no strip stores it:
  # written straight to the table, whatever metadata it is handed.
  def plant!(release: @rel, key: GRANT_KEY, marker: nil, at: NOW + 2.minutes, **metadata)
    metadata = { "granted_via" => "web" }.merge(metadata.stringify_keys)
    metadata["owner_grant"] = marker if marker
    ReleaseEvent.create!(release: release, step: "ship_authorized", status: "completed", source: "web",
                         actor: users(:alex).email, occurred_at: at, idempotency_key: key, metadata: metadata)
  end

  def unsigned_marker(user_id: users(:alex).id, slug: users(:alex).slug)
    { "user_id" => user_id, "user_slug" => slug, "at" => (NOW + 2.minutes).iso8601 }
  end

  # A marker signed here with the app's own verifier, over whichever claim the
  # test names; the defaults are the claim of a row from plant!.
  def signed_marker(release_slug: @rel.slug, step: "ship_authorized", key: GRANT_KEY, user_id: users(:alex).id,
                    slug: users(:alex).slug, verifier: Release::LaneLease.owner_grant_verifier,
                    purpose: Release::LaneLease::OWNER_GRANT_PURPOSE)
    marker = unsigned_marker(user_id: user_id, slug: slug)
    claim = Release::LaneLease.owner_grant_claim(release_slug: release_slug, step: step, idempotency_key: key, marker: marker)
    marker.merge("sig" => verifier.generate(claim, purpose: purpose))
  end

  def remark!(row, marker)
    row.update_columns(metadata: row.metadata.merge("owner_grant" => marker))
    row.reload
  end

  def shown(row)
    Release::LaneLease.answer_sentence(row, "timed")
  end

  def assert_no_approver(row, label = nil)
    sentence = shown(row)
    assert_equal LEGACY, sentence.to_s, label
    assert_equal :muted, sentence.tone, label
    assert_no_match APPROVER_WORDS, sentence.to_s, label
    refute_includes sentence.to_s, "Alex McRitchie", label
    assert_nil Release::LaneLease.approver_name(row), label
  end

  test "[unit] an unsigned marker with the owner's real id, stored with no strip, names no approver" do
    member!("first")
    request!
    row = plant!(marker: unsigned_marker)

    assert_equal users(:alex).id, row.reload.metadata.dig("owner_grant", "user_id"), "the row carries the forged marker"
    assert @rel.reload.ship_authorization_granted?, "the row still grants, as it does today"
    assert_no_approver(row)
    assert_equal [LEGACY, "Covers every task on this release when it ships: member set at authorization not recorded, 1 now."], lines
    assert_equal [:muted, :muted], sentences.map(&:tone)

    ["", "not-a-signature", 5, { "sig" => "x" }, nil].each do |sig|
      assert_no_approver(remark!(row, unsigned_marker.merge("sig" => sig)), sig.inspect)
    end

    # Control: the same row with a signature over its own claim is an approval.
    remark!(row, signed_marker)
    assert_equal "Approved by Alex McRitchie at Oct 8, 01:32 UTC, timed mode.", shown(row).to_s
    assert_equal :success, shown(row).tone
    assert_match(/member set at approval not recorded/, lines.second)
  end

  test "[unit] a real approval's marker copied onto another release's row is not an approval" do
    request!
    real = approve!
    copied = real.reload.metadata["owner_grant"]
    @rel.update_columns(state: "shipped", shipped_at: NOW + 20.minutes)
    later = Release.open!
    refute_equal @rel.slug, later.slug
    # The same idempotency key, user and time: only the release differs.
    row = plant!(release: later, key: real.idempotency_key, marker: copied, at: real.occurred_at)

    assert_equal copied, row.reload.metadata["owner_grant"]
    assert_nil Release::LaneLease.approver_name(row)
    assert_match(/\AAuthorized at .+ \(timed mode\); approver not recorded\.\z/, shown(row).to_s)
    assert_equal :muted, shown(row).tone
    # Control: on the row it was signed for, the same marker is the approval.
    assert_equal "Alex McRitchie", Release::LaneLease.approver_name(real)
    assert_equal :success, shown(real).tone
  end

  test "[unit] a signature made for another step, another row or another user does not verify" do
    request!
    row = plant!

    assert_no_approver(remark!(row, signed_marker(step: "deploy_prod")), "another step")
    assert_no_approver(remark!(row, signed_marker(key: "another-row-key")), "another row of this release")
    viewer = signed_marker(user_id: users(:viewer).id)
    assert_no_approver(remark!(row, viewer.merge("user_id" => users(:alex).id)), "signed for another user")
    assert_no_approver(remark!(row, signed_marker.merge("at" => NOW.iso8601)), "another time")
    assert_no_approver(remark!(row, signed_marker(purpose: :api_auth)), "another purpose")
    assert_no_approver(remark!(row, signed_marker(verifier: Rails.application.message_verifier("api_auth"))), "another verifier")

    # A real approval's marker, moved to a second row of the same release.
    real = approve!
    assert_equal "Alex McRitchie", Release::LaneLease.approver_name(real.reload)
    assert_no_approver(remark!(row, real.metadata["owner_grant"]), "a real marker on another row")

    # Control: the same helper, signing this row's own claim, is an approval.
    assert_equal "Approved by Alex McRitchie at Oct 8, 01:32 UTC, timed mode.", shown(remark!(row, signed_marker)).to_s
  end

  test "[unit] a verified marker whose user does not exist prints nothing from the row" do
    member!("first")
    request!
    gone = User.maximum(:id) + 1000
    row = plant!(marker: signed_marker(user_id: gone, slug: "Alex McRitchie"))

    assert Release::LaneLease.owner_grant(row), "the signature itself verifies"
    assert_no_approver(row)
    assert_match(/member set at authorization not recorded/, lines.second)

    # Control: the name is the User record's, whatever slug text the marker carries.
    remark!(row, signed_marker(slug: "somebody-else"))
    assert_equal "Approved by Alex McRitchie at Oct 8, 01:32 UTC, timed mode.", shown(row).to_s
  end

  test "[unit] a write with no idempotency key gets no marker, and a keyless row verifies none" do
    request!
    event = @rel.record_event!(step: "ship_authorized", status: "completed", source: "web", owner_grant: users(:alex))
    assert_nil event.reload.metadata["owner_grant"]

    row = plant!(key: nil, marker: signed_marker(key: ""))
    assert_nil row.reload.idempotency_key
    assert_no_approver(row)
  end

  # --- the data migration that strips stored markers ------------------------------

  def strip_stored_markers!
    require Rails.root.glob("db/migrate/*_strip_owner_grant_from_release_events.rb").sole.to_s
    ActiveRecord::Migration.suppress_messages { StripOwnerGrantFromReleaseEvents.new.up }
  end

  # { id => [metadata as text, updated_at, the row version's physical address] }
  def stored_rows
    ReleaseEvent.connection.select_rows(
      "SELECT id, metadata::text, updated_at::text, ctid::text FROM release_events ORDER BY id"
    ).to_h { |id, *rest| [id, rest] }
  end

  test "[unit] the migration strips owner_grant from stored rows and leaves every other key as it was" do
    rest = { "granted_via" => "web", "mode" => "timed", "note" => "café → ok", "n" => 1.5, "flag" => false, "none" => nil,
             "scope" => { "policy" => "release_at_ship", "member_slugs" => %w[b a] } }
    forged = plant!(key: "k-forged", marker: unsigned_marker, **rest)
    signed = plant!(key: "k-signed", marker: signed_marker(key: "k-signed"), **rest)
    scalar = plant!(key: "k-scalar", marker: "alex")
    plain = plant!(key: "k-plain", **rest)
    nested = plant!(key: "k-nested", note: { "owner_grant" => unsigned_marker })
    other = ReleaseEvent.create!(release: @rel, step: "deploy_prod", status: "completed", source: "conductor",
                                 metadata: { "owner_grant" => unsigned_marker, "sha" => "abc" })
    empty = ReleaseEvent.create!(release: @rel, step: "deploy_qa", status: "started", source: "conductor")
    before = stored_rows
    wanted = [forged, signed, scalar, plain, nested, other, empty].to_h { |row| [row.id, row.reload.metadata.except("owner_grant")] }

    strip_stored_markers!
    after = stored_rows

    assert_equal 0, ReleaseEvent.where("jsonb_exists(metadata, 'owner_grant')").count
    wanted.each { |id, metadata| assert_equal metadata, ReleaseEvent.find(id).metadata }
    assert_equal rest.merge("granted_via" => "web"), forged.reload.metadata
    assert_equal({ "sha" => "abc" }, other.reload.metadata, "any step's row is stripped")
    assert_equal unsigned_marker, nested.reload.metadata.dig("note", "owner_grant"), "only the top-level key is the marker"
    # Control: a row without the key is not rewritten at all; a stripped row keeps its other columns.
    [plain, nested, empty].each { |row| assert_equal before[row.id], after[row.id] }
    [forged, signed, scalar, other].each do |row|
      refute_equal before[row.id].first, after[row.id].first
      assert_equal before[row.id].second, after[row.id].second, "updated_at is left alone"
    end
    assert_no_approver(forged.reload)
    assert_no_approver(signed.reload)

    strip_stored_markers!
    assert_equal after, stored_rows, "a second run rewrites no row"
  end

  test "[unit] the migration's down is a no-op" do
    row = plant!(marker: unsigned_marker)
    strip_stored_markers!
    before = stored_rows

    ActiveRecord::Migration.suppress_messages { StripOwnerGrantFromReleaseEvents.new.down }

    assert_equal before, stored_rows
    assert_nil row.reload.metadata["owner_grant"]
  end

  test "[unit] auto mode says nobody was asked" do
    request!(mode: "auto")
    answer!(source: "conductor", actor: "alex", metadata: { "mode" => "auto", "granted_via" => "auto" })

    assert_equal "Proceeded on green with no approval asked at Oct 8, 01:32 UTC (auto mode).", lines.first
    assert_equal :warning, sentences.first.tone
  end

  test "[unit] a chat clearance names who cleared it, quotes the words, and stays unsigned" do
    request!(mode: "cleared")
    answer!(source: "conductor", actor: "steffon",
            metadata: { "mode" => "cleared", "granted_via" => "chat", "cleared_by" => "alex", "clearance" => "ship it" })

    assert_equal "Cleared in chat by alex, asserted by the conductor CLI (run as steffon) at Oct 8, 01:32 UTC; unsigned. \"ship it\".",
                 lines.first
    assert_equal :warning, sentences.first.tone, "a chat clearance never reads in the success tone a signed tap gets"

    state = @rel.ship_authorization_state
    assert state["granted"]
    assert_equal "chat", state["granted_via"]
    assert_equal "alex", state["cleared_by"]
    assert_equal "ship it", state["clearance"]
    assert_nil state["window_ends_at"], "a cleared grant posts no window"
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
