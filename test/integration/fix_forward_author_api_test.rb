# frozen_string_literal: true

require "test_helper"

# [integration] THE FIX-FORWARD RECORD, DRIVEN THROUGH THE WIRE `bin/task
# fix-forward` WRITES — one devops PATCH, no stage move, no build claim.
#
# The unit tier (test/models/reviewer_fix_forward_author_test.rb) drives the model.
# This one drives the API, because the defect it closes is about what the BOARD does
# with an ordinary PATCH, and because three separate properties only exist on the
# wire: `fix_forward` has to survive normalize_devops_metadata (it is a
# DEVOPS_LIST_KEY, so an unlisted name would be silently dropped and the whole
# command would report success while recording nothing); the fold has to reach
# server-owned `devops.builders`, which a client is forbidden to write directly; and
# a partial devops post must not wipe the keys it does not mention.
#
# THE MEASURED SHAPE. On PR #1321 steffon zapped be5579a5 while holding the light
# seat and `bin/reviewer-select` then seated STEFFON on a PR containing steffon's own
# commit; on #1322 the reviewer pushed 7113af85 and had to disclose it in prose.
# Neither commit identifies its soul — both are authored `Alex McRitchie
# <amcritchie@gmail.com>`, like 214 of the last 400 commits on `accepted` — so the
# record is the ONLY place this fact can live.
class FixForwardAuthorApiTest < ActionDispatch::IntegrationTest
  BUILDER_SESSION = "b1d0f2a3-4b5c-4d6e-8f90-a1b2c3d4e5f6"

  def token = Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth)

  def auth = { "Authorization" => "Bearer #{token}" }

  def patch_task(slug, params)
    patch "/api/v1/tasks/#{slug}", params: params, headers: auth, as: :json
    assert_response :success
  end

  def devops_of(slug)
    get "/api/v1/tasks/#{slug}", headers: auth, as: :json
    assert_response :success
    JSON.parse(response.body).dig("data", "metadata", "devops") || {}
  end

  # A submitted task with ONE author on record, built the way the pipeline builds it.
  def submitted_task(builder: "shannon")
    task = Task.create!(title: "Fix Forward Wire Task", stage: "designed",
                        metadata: { "devops" => { "shape" => "backend",
                                                  "repositories" => ["mcritchie-studio"],
                                                  "pr_url" => "https://github.com/o/r/pull/1321" } })
    patch_task(task.slug, stage: "building", event: { actor: builder },
                          devops: ClaimLease.renewed(session: BUILDER_SESSION, nonce: "inst-B"))
    patch_task(task.slug, stage: "submitted", event: { actor: BUILDER_SESSION })
    task.reload
  end

  # Exactly what `bin/task fix-forward <slug> --agent <soul>` puts on the wire.
  def fix_forward!(slug, *entries)
    patch_task(slug, devops: { "fix_forward" => entries })
  end

  def test_a_named_fix_forward_joins_the_server_owned_author_set
    task = submitted_task(builder: "shannon")
    fix_forward!(task.slug, "steffon")
    devops = devops_of(task.slug)

    assert_equal ["steffon"], devops["fix_forward"],
                 "fix_forward must be a storable devops key, or the write reports success and records nothing"
    assert_equal %w[shannon steffon], Array(devops["builders"]),
                 "the zapper joins the SERVER-OWNED author set a client cannot write directly"
    assert_equal "shannon", devops["built_by"],
                 "and never re-points built_by — a reviewer is an author, not the current builder"
  end

  # THE PROPERTY, over the PERSISTED record: the selector reads the task the board
  # actually stored and refuses to seat the soul who pushed to its PR.
  def test_the_selector_excludes_the_zapper_from_the_persisted_record
    task = submitted_task(builder: "shannon")
    control = ReviewerSelector.new(task.reload).decision
    assert_includes control["candidates"], "steffon",
                    "control: before the record exists, the zapper is a free reviewer of his own commit"

    fix_forward!(task.slug, "steffon")
    decision = ReviewerSelector.new(task.reload).decision

    assert_includes Array(decision["excluded_builders"]), "steffon"
    refute_includes Array(decision["reviewers"]).map { |r| r["slug"] }, "steffon"
  end

  # The stage must NOT move. `bin/task move <slug> building --actor <soul>` is the
  # documented repair for a MISSING builder stamp and it is the wrong instrument
  # here: it would drag a submitted task back onto `building` mid-review.
  def test_recording_a_fix_forward_moves_no_stage_and_claims_no_build
    task = submitted_task(builder: "shannon")
    fix_forward!(task.slug, "steffon")

    assert_equal "submitted", task.reload.stage
    assert_nil task.devops["claimed_session"].presence,
               "a fix-forward is not a build claim and must leave no lease behind"
  end

  # A partial devops post must not wipe what it does not mention — the
  # api-devops-patch-replaces trap, re-asserted at this new write site.
  def test_the_partial_post_preserves_the_rest_of_devops
    task = submitted_task(builder: "shannon")
    fix_forward!(task.slug, "steffon")
    devops = devops_of(task.slug)

    assert_equal "backend", devops["shape"]
    assert_equal ["mcritchie-studio"], Array(devops["repositories"])
    assert_equal "https://github.com/o/r/pull/1321", devops["pr_url"]
  end

  # The fail-closed half on the wire: an unattributable fix-forward is recorded as
  # such, is NOT laundered into an author, and makes the selector refuse.
  def test_an_unnamed_fix_forward_is_recorded_and_refuses
    task = submitted_task(builder: "shannon")
    fix_forward!(task.slug, "unattributed")
    devops = devops_of(task.slug)

    assert_equal ["unattributed"], Array(devops["fix_forward"])
    assert_equal ["shannon"], Array(devops["builders"]),
                 "a marker names no soul and must never be folded in as an author"
    refute ReviewerSelector.new(task.reload).decision["builder_known"],
           "a fix-forward nobody can attribute leaves the author set INCOMPLETE"
  end
end
