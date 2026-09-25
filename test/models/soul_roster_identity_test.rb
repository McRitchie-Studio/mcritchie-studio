# frozen_string_literal: true

# THE ROSTER IS AN IDENTITY REGISTER, NOT A REVIEW REGISTER.
#
# `Task.soul?` answers "is this SOMEBODY" — the question every authorship guard asks
# before it will stamp a builder or exclude an author. Who may REVIEW is a different
# question with a different answer, held by `ReviewerSelector::POOL` and
# `Agent.metadata["reviewer"]`. Reading the roster as a review register is what kept
# two working souls off it:
#
#   POKEMON — the general builder the operating model routes every task through, and
#     so the most prolific author in the ecosystem. `--agent pokemon` passed the
#     CLI's shape check and died at the roster, silently: the build claim reported
#     success, the author set stayed empty, and `bin/reviewer-select` then failed
#     CLOSED, leaving the no-self-review property unverified for that review.
#     Measured against prod 2026-09-24: soul-character-reference-lane carries
#     agent_slug "pokemon" with built_by nil and builders []. The refusal was FALSE
#     — Pokémon is not in POOL, so naming it excludes nobody and frees no seat.
#
#   REX — the CMO. A launcher, a docs directory, a HEARTBEAT and two registered SOPs,
#     never on the register. Measured the same day: zero attributed rows, so the gap
#     was LATENT — it fires the first time Rex authors anything.
#
# The tests below pin the two halves that must not drift back together: a soul on the
# roster is ATTRIBUTABLE, and a soul on the roster is still not ELIGIBLE TO REVIEW.
require "test_helper"

class SoulRosterIdentityTest < ActiveSupport::TestCase
  # UUID-shaped, like a real session id — a soul-shaped stand-in takes a different
  # path through Task#disowned? (see TaskBuilderRollCallTest).
  BUILD_SESSION = "s1d0f2a3-4b5c-4d6e-8f90-a1b2c3d4e5f6"

  def new_task(devops = {})
    Task.create!(title: "Soul Roster Task", stage: "designed", metadata: { "devops" => devops })
  end

  # The build CLAIM is the moment the author set is stamped, and only a real lease
  # rewrite counts as one — mirrors TaskBuilderRollCallTest#claim!.
  def claim!(task, actor:, session: BUILD_SESSION, nonce: "inst-A")
    @clock = (@clock || Time.current) + 30.seconds
    Current.task_event_actor = actor
    task.update!(stage: "building",
                 metadata: { "devops" => task.devops.merge(
                   ClaimLease.renewed(session: session, nonce: nonce, now: @clock)
                 ) })
  ensure
    Current.reset
  end

  # --- the register names everyone who actually works here --------------------

  test "the general builder and the CMO are souls" do
    assert Task.soul?("pokemon"), "pokemon authors more tasks than any other soul"
    assert Task.soul?("rex"), "rex has a launcher, a heartbeat and two registered SOPs"
  end

  test "a Pokemon build claim stamps the author set" do
    task = new_task
    claim!(task, actor: "pokemon")

    assert_equal "pokemon", task.reload.devops["built_by"]
    assert_equal %w[pokemon], task.devops["builders"],
      "a Pokemon-built task must never come back NOT STAMPED"
  end

  test "a Rex build claim stamps the author set" do
    task = new_task
    claim!(task, actor: "rex")

    assert_equal "rex", task.reload.devops["built_by"]
    assert_equal %w[rex], task.devops["builders"]
  end

  # --- what the register must NOT do ------------------------------------------

  test "the register still refuses a name that identifies nobody" do
    %w[stefon shanon jaspar carll pokemonn pokmon rexx].each do |typo|
      refute Task.soul?(typo), "#{typo} is not on the roster"
    end
  end

  test "a typo'd builder still leaves the author set empty" do
    task = new_task
    claim!(task, actor: "pokemonn")

    assert_nil task.reload.devops["built_by"],
      "widening the roster must not widen it to near-misses"
    assert_nil task.devops["builders"]
  end

  test "being on the register does not grant a review seat" do
    %w[pokemon rex turf-monster mack mason].each do |soul|
      assert Task.soul?(soul), "#{soul} is attributable"
      refute_includes ReviewerSelector::POOL, soul,
        "#{soul} builds or works; the roster answers identity, POOL answers review"
    end
  end

  # --- degraded mode: the STATIC FLOOR must name them -------------------------
  #
  # Task.soul_roster rescues to SOUL_ROSTER on any DB error, and the guarantee that
  # buys is "degrading never turns a real soul into an unknown". A soul added only to
  # db/seeds/02_agents.rb would void that guarantee for exactly the new names — it
  # would resolve while the Agent table is readable and become an unknown the moment
  # it is not, which is the one condition the floor exists for.

  test "the new souls survive an unreadable Agent table" do
    Current.soul_roster = nil
    Agent.stub(:pluck, ->(*) { raise ActiveRecord::StatementInvalid, "no such table" }) do
      assert Task.soul?("pokemon"), "pokemon is in the static floor, not only in the seed"
      assert Task.soul?("rex"), "rex is in the static floor, not only in the seed"
      refute Task.soul?("stefon"), "and a typo is still nobody with the DB down"
    end
  ensure
    Current.soul_roster = nil
  end

  # --- the new entries are souls in their own right, not aliases --------------
  #
  # Task::SOUL_ALIASES owns the retired-slug behaviour and test/models/soul_alias_test.rb
  # owns its assertions; this only pins that neither new name was added THROUGH it.
  # An alias entry would make pokemon or rex stamp as somebody else — which is the
  # `--agent mack` placeholder again, wearing a different hat.

  test "the new souls are their own canonical slug, not aliases of another" do
    assert_equal "pokemon", Task.canonical_soul("pokemon")
    assert_equal "rex", Task.canonical_soul("rex")
    assert_empty Task::SOUL_ALIASES.values & %w[pokemon rex],
      "nothing may be aliased ONTO a builder seat either"
  end

  # --- the property all of this feeds -----------------------------------------

  test "reviewer selection stops failing closed on a Pokemon build" do
    task = new_task("shape" => "backend")
    claim!(task, actor: "pokemon")

    decision = ReviewerSelector.explain(task.reload)
    assert_equal true, decision["builder_known"],
      "the record DOES say who built this, so the refusal was false"
    assert_equal %w[pokemon], decision["builders"]
    assert_nil decision["excluded_builder"],
      "pokemon is not in the light pool, so excluding it removes nobody"
    assert_empty Array(decision["kept_builders"]),
      "and nothing is kept back, so bin/reviewer-select has nothing to refuse on"
  end

  # ONE IDENTITY MUST NOT HOLD TWO SEATS. test/models/soul_alias_test.rb proves the
  # alias at the MODEL layer (canonical_soul, soul?, the stamp); nothing proved it
  # where it actually matters — the pool. A roster entry and a pool entry that drift
  # apart for one soul is a live no-self-review violation, not a cosmetic one: the
  # author is excluded under a name the pool does not carry, so nobody is removed.
  # Pinned here because this file is what widens the roster, and the next widening
  # is exactly when a split identity gets introduced by accident.
  test "a task stamped under the RETIRED slug still excludes the seat it names" do
    task = new_task("shape" => "docs", "built_by" => "alex")

    decision = ReviewerSelector.explain(task.reload)
    assert_equal true, decision["builder_known"], "the retired slug still names somebody"
    assert_equal %w[xan], decision["builders"], "and it resolves to the one identity"
    refute_includes decision["candidates"], "xan",
      "a historical alex stamp must keep xan out of the pool — same soul, other name"
    assert_empty Array(decision["kept_builders"])
  end

  test "a Pokemon build leaves every specialist eligible for the light seat" do
    # The reason naming Pokémon is free: it frees no seat and costs none. This is the
    # same outcome the `--agent mack` placeholder bought, without putting untrue
    # authorship on the record.
    task = new_task("shape" => "backend")
    claim!(task, actor: "pokemon")

    candidates = ReviewerSelector.explain(task.reload)["candidates"]
    (ReviewerSelector::POOL - [ReviewerSelector::STANDING_PRIMARY,
                               ReviewerSelector::DEFAULT_QA_OWNER]).each do |soul|
      assert_includes candidates, soul, "#{soul} must stay eligible on a Pokemon build"
    end
  end
end
