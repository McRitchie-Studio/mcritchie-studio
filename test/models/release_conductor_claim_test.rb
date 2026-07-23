# frozen_string_literal: true

require "test_helper"
# The renewer's cadence is what keeps the claim lease below alive, so the headless-hold
# window test drives the REAL constant rather than a number retyped here. It lives in
# bin/lib (plain Ruby, so the standalone CLI can load it) and is not on the Rails
# autoload path.
require_relative "../../bin/lib/shift_renewer"

# Unit coverage for the ReleaseConductorClaim lease — acquire / renew / release /
# self-heal, per (release, role), reusing the ClaimLease math. The atomic CAS itself
# (with_lock over the composite unique index) is exercised through the disposition
# paths AND asserted directly; true concurrency is covered by the controller
# integration test.
class ReleaseConductorClaimTest < ActiveSupport::TestCase
  REL = "rel-20260721-abc123"
  A = { session: "sess-A", nonce: "inst-A" }.freeze
  B = { session: "sess-B", nonce: "inst-B" }.freeze
  RESUME_A2 = { session: "sess-A", nonce: "inst-A2" }.freeze # same session, second terminal

  def acquire(release_slug: REL, role: "assembler", now: Time.current, label: nil, **who)
    ReleaseConductorClaim.acquire(
      release_slug: release_slug, role: role, session: who[:session], nonce: who[:nonce], label: label, now: now
    )
  end

  test "roles are a closed set — an unknown role is invalid" do
    claim = ReleaseConductorClaim.new(release_slug: REL, role: "wrangler")
    refute claim.valid?
    assert_includes claim.errors[:role], "is not included in the list"
    assert_equal %w[assembler deployer], ReleaseConductorClaim::ROLES
  end

  test "a free (release, role) is claimed by the first instance" do
    out = acquire(**A, label: "Snorlax")
    assert out.acquired
    assert_equal :unclaimed, out.disposition
    assert_equal "sess-A", out.claim.claimed_session
    assert_equal "assembler", out.claim.role
    assert_equal "Snorlax", out.claim.holder_label
    assert out.claim.live?
  end

  test "a second live instance is refused and sees the holder" do
    acquire(**A, label: "Snorlax")
    out = acquire(**B)

    refute out.acquired, "a second conductor must not take a release+role already held"
    assert_equal :held_by_other, out.disposition
    assert_equal "sess-A", out.claim.claimed_session, "still held by A"
    assert_equal "Snorlax", out.claim.holder_label
  end

  test "a resume of the SAME session in a second terminal is also refused (nonce differs)" do
    acquire(**A)
    out = acquire(**RESUME_A2)
    refute out.acquired, "a second terminal on the same session id is a distinct live instance"
    assert_equal :held_by_other, out.disposition
  end

  # THE RESUME PROPERTY — an interrupted ship re-run must RESUME, not stand itself down.
  test "the same instance re-acquiring renews and preserves acquired_at (interrupted ship resumes)" do
    t0 = Time.utc(2026, 7, 21, 3, 0, 0)
    first = acquire(**A, role: "deployer", now: t0)
    original_acquired = first.claim.acquired_at

    again = acquire(**A, role: "deployer", now: t0 + 30)
    assert again.acquired, "a same-instance re-acquire succeeds — this is what lets a killed ship re-run resume"
    assert_equal :same_instance, again.disposition
    assert_equal original_acquired.to_i, again.claim.acquired_at.to_i, "acquired_at is stable across a renew"
    assert_operator again.claim.claim_expires_at, :>, first.claim.claim_expires_at, "the lease was extended"
  end

  test "an EXPIRED lease self-heals — the next conductor takes over (per role)" do
    ReleaseConductorClaim::ROLES.each do |role|
      slug = "#{REL}-#{role}"
      t0 = Time.utc(2026, 7, 21, 3, 0, 0)
      acquire(release_slug: slug, role: role, **A, now: t0)
      out = acquire(release_slug: slug, role: role, **B,
                    now: t0 + ClaimLease::DEFAULT_TTL_SECONDS + 1, label: "Gengar")
      assert out.acquired, "a lapsed #{role} lease is reclaimable"
      assert_equal :expired, out.disposition
      assert_equal "sess-B", out.claim.claimed_session
      assert_equal "Gengar", out.claim.holder_label
    end
  end

  test "a change-of-hands after expiry does NOT inherit the prior holder's label" do
    t0 = Time.utc(2026, 7, 21, 3, 0, 0)
    acquire(**A, now: t0, label: "Snorlax")
    out = acquire(**B, now: t0 + ClaimLease::DEFAULT_TTL_SECONDS + 1, label: nil)
    assert out.acquired
    assert_equal :expired, out.disposition
    assert_equal "sess-B", out.claim.claimed_session
    assert_nil out.claim.holder_label, "a new holder must not wear the crashed prior holder's label"
  end

  test "a same-instance renew with no label keeps the holder's existing label" do
    t0 = Time.utc(2026, 7, 21, 3, 0, 0)
    acquire(**A, now: t0, label: "Snorlax")
    out = acquire(**A, now: t0 + 30, label: nil)
    assert_equal :same_instance, out.disposition
    assert_equal "Snorlax", out.claim.holder_label, "a renew keeps the label it was acquired with"
  end

  test "renew extends only for the holder, never steals" do
    t0 = Time.utc(2026, 7, 21, 3, 0, 0)
    acquire(**A, now: t0)

    assert ReleaseConductorClaim.renew(release_slug: REL, role: "assembler", session: "sess-A", nonce: "inst-A",
                                       now: t0 + 10)
    refute ReleaseConductorClaim.renew(release_slug: REL, role: "assembler", session: "sess-B", nonce: "inst-B",
                                       now: t0 + 10),
           "a non-holder cannot renew (and thus cannot steal via renew)"
    assert_equal "sess-A", ReleaseConductorClaim.find_by(release_slug: REL, role: "assembler").claimed_session
  end

  test "release frees the (release, role) only for the holder" do
    acquire(**A)
    refute ReleaseConductorClaim.release(release_slug: REL, role: "assembler", session: "sess-B", nonce: "inst-B"),
           "a non-holder cannot release"
    assert ReleaseConductorClaim.release(release_slug: REL, role: "assembler", session: "sess-A", nonce: "inst-A")

    row = ReleaseConductorClaim.find_by(release_slug: REL, role: "assembler")
    assert_nil row.claimed_session
    refute row.live?
    # the freed (release, role) is immediately claimable by anyone
    assert acquire(**B).acquired
  end

  # BOTH ROLES INDEPENDENT — an assembler and a deployer on ONE release never contend.
  test "the two roles on one release are independent rows" do
    assert acquire(role: "assembler", **A).acquired
    assert acquire(role: "deployer", **B).acquired,
           "the deployer claim coexists with the assembler claim on the same release"

    # And each is its OWN lease: releasing assembler leaves deployer held.
    assert ReleaseConductorClaim.release(release_slug: REL, role: "assembler", session: "sess-A", nonce: "inst-A")
    assert ReleaseConductorClaim.find_by(release_slug: REL, role: "deployer").live?, "deployer survives the assembler release"
  end

  test "different releases never contend for the same role" do
    assert acquire(release_slug: "rel-one", **A).acquired
    assert acquire(release_slug: "rel-two", **B).acquired, "a deploy on one release coexists with a deploy on another"
  end

  test "release_slug + role are normalized so ' REL '/'Assembler' collide with the canonical form" do
    assert acquire(release_slug: " #{REL} ", role: "Assembler", **A).acquired
    refute acquire(release_slug: REL, role: "assembler", **B).acquired, "the normalized (slug, role) collides"
  end

  # --- [unit] THE PROPERTY: a headless conductor RETAINS the release -------------
  #
  # The invariant the whole feature rests on: a release conductor that is headless
  # (no status line ⇒ no UI renewal) must still keep its (release, role) for the act's
  # whole life, so a second parallel session is refused throughout and never
  # double-assembles / double-ships. This walks a 20-minute window — ten TTLs —
  # renewing on the RENEWER's cadence (bin/lib/shift_renewer.rb, independent of any UI)
  # and asserts a second instance is refused at EVERY point in it.
  test "a headless conductor keeps the release across the whole window, second acquire refused throughout" do
    t0 = Time.utc(2026, 7, 21, 4, 0, 0)
    ttl = ClaimLease::DEFAULT_TTL_SECONDS
    beat = ShiftRenewer::INTERVAL_SECONDS

    assert acquire(**A, role: "deployer", now: t0, label: "Machamp").acquired

    work_window = 20.minutes.to_i
    checks = 0
    (beat..work_window).step(beat) do |elapsed|
      now = t0 + elapsed
      assert ReleaseConductorClaim.renew(release_slug: REL, role: "deployer", session: A[:session], nonce: A[:nonce],
                                         now: now),
             "the conductor's own renewer must keep the deployer lease alive at t+#{elapsed}s"

      out = acquire(**B, role: "deployer", now: now)
      refute out.acquired,
             "a second deployer must be REFUSED at t+#{elapsed}s — this is the double-ship the claim prevents"
      assert_equal :held_by_other, out.disposition
      checks += 1
    end

    assert_operator checks, :>, work_window / ttl,
                    "the window must span several TTLs, or it proves nothing about the lapse"
    assert_equal "sess-A", ReleaseConductorClaim.find_by(release_slug: REL, role: "deployer").claimed_session,
                 "still A's ship at the end"
  end

  # The other half, and the reason we did NOT make acquire fail closed: a crashed
  # conductor must never wedge a release. Its renewer dies with it, so nothing renews,
  # and the release is reclaimable one TTL later.
  test "a genuinely dead conductor stops renewing and the release is reclaimable" do
    t0 = Time.utc(2026, 7, 21, 4, 0, 0)
    assert acquire(**A, now: t0).acquired

    dead_at = t0 + ClaimLease::DEFAULT_TTL_SECONDS + 1
    refute ReleaseConductorClaim.renew(release_slug: REL, role: "assembler", session: A[:session], nonce: A[:nonce],
                                       now: dead_at),
           "a lapsed lease cannot be renewed back to life"

    out = acquire(**B, now: dead_at)
    assert out.acquired, "a crash must never deadlock a release"
    assert_equal :expired, out.disposition
    assert_equal "sess-B", out.claim.claimed_session
  end

  # --- [unit] THE ATOMIC GUARD: the composite unique index makes acquire a CAS -----
  #
  # acquire's correctness (two racers → exactly one winner) rests on ONE row per
  # (release_slug, role) taken under with_lock. If the unique index were dropped, two
  # first-acquirers could both INSERT and both "win". This asserts the DB refuses a
  # second row for the same (slug, role), and that claim_row tolerates that race by
  # re-reading the winner's row instead of raising.
  test "the composite unique index forbids a second claim row for one (release, role)" do
    ReleaseConductorClaim.create!(release_slug: REL, role: "assembler")
    assert_raises(ActiveRecord::RecordNotUnique) do
      # bypass the model so we test the DB constraint itself, not the uniqueness validation
      ReleaseConductorClaim.connection.execute(
        "INSERT INTO release_conductor_claims (release_slug, role, created_at, updated_at) " \
        "VALUES ('#{REL}', 'assembler', NOW(), NOW())"
      )
    end
  end

  test "a second row for the SAME release but a DIFFERENT role is allowed" do
    ReleaseConductorClaim.create!(release_slug: REL, role: "assembler")
    assert ReleaseConductorClaim.create!(release_slug: REL, role: "deployer").persisted?,
           "the unique index is composite — the other role on the same release is a distinct row"
  end

  test "claim_row tolerates the create race and returns the single winning row" do
    first = ReleaseConductorClaim.claim_row(REL, "assembler")
    second = ReleaseConductorClaim.claim_row(REL, "assembler")
    assert_equal first.id, second.id, "both first-acquirers converge on ONE row (the unique index enforces it)"
  end

  # --- [unit] GAP 1: the FORMING sentinel + the hand-off to the real claim --------
  #
  # A brand-new qa-release promotes `accepted → release` BEFORE any release record
  # exists, so there is no real slug to claim. Two concurrent fresh sessions guard the
  # promote by claiming the reserved FORMING_SLUG sentinel instead — an atomic CAS, so
  # exactly one may promote. Then the winner hands off to the real (rel_slug) claim and
  # frees the sentinel, with ownership continuous across the hand-off (never a gap).
  test "FORMING_SLUG is a reserved sentinel no real release can collide with" do
    assert_equal "__forming__", ReleaseConductorClaim::FORMING_SLUG
  end

  test "the forming sentinel is an atomic CAS — one fresh session wins, the other stands down" do
    won = acquire(release_slug: ReleaseConductorClaim::FORMING_SLUG, **A, label: "Snorlax")
    assert won.acquired, "the first fresh qa-release takes the forming sentinel and may promote"

    lost = acquire(release_slug: ReleaseConductorClaim::FORMING_SLUG, **B)
    refute lost.acquired, "a second concurrent fresh qa-release must STAND DOWN — it cannot also promote"
    assert_equal :held_by_other, lost.disposition
    assert_equal "Snorlax", lost.claim.holder_label
  end

  test "the hand-off holds the real claim AND the sentinel at once, then frees ONLY the sentinel" do
    forming = ReleaseConductorClaim::FORMING_SLUG
    real = "rel-20260721-fresh"

    # 1. Fresh session A guards the promote with the sentinel.
    assert acquire(release_slug: forming, **A).acquired

    # 2. The release now exists; A takes the REAL claim BEFORE releasing the sentinel —
    #    so at THIS instant it holds BOTH (continuous ownership, no gap across hand-off).
    assert acquire(release_slug: real, **A).acquired
    assert ReleaseConductorClaim.find_by(release_slug: forming, role: "assembler").live?, "sentinel still live"
    assert ReleaseConductorClaim.find_by(release_slug: real, role: "assembler").live?, "real claim now live too"

    # 3. Hand-off: free ONLY the sentinel. The real claim must be untouched, and the
    #    sentinel must be free for the next fresh session.
    assert ReleaseConductorClaim.release(release_slug: forming, role: "assembler", session: A[:session], nonce: A[:nonce])
    refute ReleaseConductorClaim.find_by(release_slug: forming, role: "assembler").live?, "sentinel released"
    assert ReleaseConductorClaim.find_by(release_slug: real, role: "assembler").live?,
           "the REAL claim survives the sentinel hand-off — the assembly is still guarded"
    assert acquire(release_slug: forming, **B).acquired, "a later fresh session can take the freed sentinel"
  end

  # --- [unit] GAP 2: the deployer claim across ship → finalize --------------------
  #
  # `finalize` (the `--finalize-only` / `bin/release finalize` resume path) records the
  # steps a killed ship skipped — real mutation — and must hold the SAME deployer claim
  # the normal ship holds. A second finalize (or a finalize racing a fresh ship) stands
  # down; a `ship → finalize` in ONE session (same instance) renews and RESUMES.
  test "a second finalize on a release already being deployed stands down" do
    rel = "rel-20260721-ship"
    assert acquire(release_slug: rel, role: "deployer", **A).acquired, "the ship/finalize holds the deployer claim"
    out = acquire(release_slug: rel, role: "deployer", **B)
    refute out.acquired, "a second concurrent finalize/ship must STAND DOWN — no double-record"
    assert_equal :held_by_other, out.disposition
  end

  test "a ship→finalize (or resumed finalize) in one session renews the deployer claim, never stands down" do
    rel = "rel-20260721-ship"
    t0 = Time.utc(2026, 7, 21, 5, 0, 0)
    ship = acquire(release_slug: rel, role: "deployer", **A, now: t0)
    assert ship.acquired
    original = ship.claim.acquired_at

    # The SAME session later runs `bin/release finalize` (same session + nonce).
    finalize = acquire(release_slug: rel, role: "deployer", **A, now: t0 + 45)
    assert finalize.acquired, "finalize from the same live instance RESUMES — it must not stand itself down"
    assert_equal :same_instance, finalize.disposition
    assert_equal original.to_i, finalize.claim.acquired_at.to_i, "acquired_at is stable across the ship→finalize resume"
  end

  # --- [unit] OPERATOR OVERRIDE: force-reassign a LIVE claim -----------------------
  #
  # `acquire` deliberately STANDS DOWN on a live holder (the anti-double-assembly
  # guarantee), so a stuck/ghost holder strands the (release, role) until its TTL
  # lapses. `reassign` is the operator's escape hatch: it hands the claim to the session
  # asking even over a live holder, so the next prepare/ship resumes as :same_instance.
  test "[unit] reassign force-takes a LIVE claim that acquire would refuse" do
    held = acquire(**A, label: "Snorlax")
    assert held.acquired
    # A different instance can NOT acquire — it stands down (the property reassign overrides).
    refute acquire(**B).acquired, "precondition: a live holder refuses a normal acquire"

    out = ReleaseConductorClaim.reassign(release_slug: REL, role: "assembler",
                                         session: B[:session], nonce: B[:nonce], label: "Gengar")
    assert out.acquired
    assert_equal :reassigned, out.disposition
    assert_equal "sess-B", out.claim.claimed_session, "the claim now belongs to the session asking"
    assert_equal "Gengar", out.claim.holder_label
    assert out.claim.live?
  end

  test "[unit] after reassign the new holder acquires as same_instance (its ship resumes)" do
    acquire(**A, label: "Snorlax")
    ReleaseConductorClaim.reassign(release_slug: REL, role: "assembler",
                                   session: B[:session], nonce: B[:nonce], label: "Gengar")
    resumed = acquire(**B)
    assert resumed.acquired, "the reassigned session now holds it, so its next acquire is a renew"
    assert_equal :same_instance, resumed.disposition
  end

  test "[unit] a same-instance reassign keeps acquired_at and the existing label" do
    t0 = Time.utc(2026, 7, 21, 3, 0, 0)
    first = acquire(**A, now: t0, label: "Snorlax")
    original = first.claim.acquired_at
    out = ReleaseConductorClaim.reassign(release_slug: REL, role: "assembler",
                                         session: A[:session], nonce: A[:nonce], now: t0 + 30)
    assert_equal :reassigned, out.disposition
    assert_equal original.to_i, out.claim.acquired_at.to_i, "re-arming the SAME instance keeps acquired_at"
    assert_equal "Snorlax", out.claim.holder_label, "no new label keeps the holder's label"
  end

  test "[unit] reassign only touches its own (release, role) row" do
    acquire(role: "assembler", **A)
    acquire(role: "deployer", **A, label: "Machamp")
    ReleaseConductorClaim.reassign(release_slug: REL, role: "assembler",
                                   session: B[:session], nonce: B[:nonce])
    assert_equal "sess-B", ReleaseConductorClaim.find_by(release_slug: REL, role: "assembler").claimed_session
    assert_equal "sess-A", ReleaseConductorClaim.find_by(release_slug: REL, role: "deployer").claimed_session,
                 "reassigning the assembler leaves the deployer claim untouched"
  end

  test "status_for reports the holder and heartbeat age, nil when never claimed" do
    assert_nil ReleaseConductorClaim.status_for("never-claimed", "deployer")

    t0 = Time.utc(2026, 7, 21, 3, 0, 0)
    acquire(**A, now: t0, label: "Snorlax")
    info = ReleaseConductorClaim.status_for(REL, "assembler", now: t0 + 5)
    assert info["live"]
    assert_equal "assembler", info["role"]
    assert_equal "Snorlax", info["label"]
    assert_equal 5, info["heartbeat_age"]
  end
end
