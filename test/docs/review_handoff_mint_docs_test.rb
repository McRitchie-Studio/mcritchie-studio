# frozen_string_literal: true

require "test_helper"

# GUARD (handoff-recipe-mints-wrong-db, 2026-09-09): the review-handoff recipe is
# copied by every agent at every handoff, so a wrong recipe here does not produce
# a stale sentence — it produces a link that is dead on arrival, handed to Mr.
# McRitchie as if it worked.
#
# THE DEFECT THIS PINS. The recipe used to be a console mint:
#
#   bin/rails runner 'Studio::Link.create_magic_link(...)'
#
# A desk stack owns its own database through DATABASE_URL in .env.agent-stack,
# and nothing in config/ or bin/ loads that file — so a bare `bin/rails runner`
# in a worktree falls through config/database.yml to the SHARED development
# database. Measured 2026-09-09 in a mcritchie-studio desk: the bare runner bound
# `mcritchie_studio_development` while the desk server served
# `mcritchie_studio_development_handoff_recipe_mints_wrong_db`, and the token it
# minted answered `302 -> /login` on that server. The same mint driven through
# `/_studio/local_review` answered `200`, signed in.
#
# It failed quietly and it failed often: 26 links minted into turf-monster's
# shared development database over three days, exactly ONE ever consumed.
#
# WHY THE ASSERTIONS BELOW ARE SHAPED THIS WAY. The obvious test — grep the file
# for `create_magic_link` and refute it — fails as a guard twice over:
#
#   1. The METHOD NAME is not the defect. `create_magic_link` is correct code,
#      and the endpoint calls it too; what went wrong is WHICH DATABASE the row
#      landed in. A name-grep would equally flag a correct mention and pass a
#      broken recipe that spelled the mint some other way.
#   2. A bare refutation passes if someone DELETES the recipe. Absence is not
#      correctness, so every refutation here is paired with a positive claim
#      about the mechanism the recipe must still teach.
#
# So the property asserted is not "a string is absent" but "the path the agent is
# told to hand over MINTS IN-REQUEST, on the server that will serve the click" —
# which is what makes the database right by construction. Editing the recipe back
# to any out-of-band console mint reddens `the recipe mints in-request, not in a
# console`, whatever words surround it.
class ReviewHandoffMintDocsTest < ActiveSupport::TestCase
  MODULE_DOC = Rails.root.join("docs", "agents", "modules", "communication-style.md")
  ROOT_DOC   = Rails.root.join("docs", "agents", "index.md")

  # The endpoint IS the mechanism: it mints inside the request the desk server is
  # already handling, so the row cannot land in another database.
  IN_REQUEST_MINT = "/_studio/local_review"

  # Any mint that happens OUT of the request — a console, a runner, a rake task —
  # is the defect class, whatever it is spelled. The database it binds is decided
  # by the process's env, not by the server that will serve the link.
  OUT_OF_BAND_MINT = /rails\s+runner|rails\s+console|bin\/rails\s+c\b|create_magic_link/

  setup do
    @body = MODULE_DOC.read

    # Scope to the recipe, not the file. The module is long, and a match anywhere
    # else would let the copied block itself rot unnoticed.
    @recipe = @body[/^\*\*Hand him a MINT URL.*?(?=^### )/m]
    refute_nil @recipe,
               "the handoff recipe must exist — deleting it is not a way to pass this test"

    # The labels block is what actually reaches chat. A correct recipe above a
    # stale label still hands him the dead link.
    @labels = @body[/^Task: https:\/\/mcritchie\.studio\/tasks\/<slug>.*?^Local Demo:.*$/m]
    refute_nil @labels, "the handoff must still show the exact labels to paste"
  end

  # THE CENTRAL ASSERTION. Not "the old string is gone" — "the mint the agent is
  # told to run happens in-request".
  test "the recipe mints in-request, not in a console" do
    assert_includes @recipe, IN_REQUEST_MINT,
                    "the handoff recipe must hand over the stack's own in-request mint endpoint; " \
                    "a mint that happens anywhere else picks its database from the env, not from " \
                    "the server that will serve the click"

    offenders = @recipe.scan(OUT_OF_BAND_MINT)
    assert_empty offenders,
                 "the recipe must not tell an agent to mint out of band (#{offenders.uniq.inspect}). " \
                 "On a desk that binds the SHARED development database and the link 302s to /login."
  end

  # The label is the payload. Everything above it is advice; this line is what
  # gets pasted into chat, so it is pinned to the same mechanism.
  test "the Magic Link label carries the mint URL, not a minted token" do
    magic = @labels[/^Magic Link: (.*)$/, 1]

    refute_nil magic, "the handoff must keep the `Magic Link:` label"
    assert_includes magic, IN_REQUEST_MINT,
                    "the label must show the reusable mint URL"
    refute_match %r{/l/<token>}, magic,
                 "a pre-minted /l/<token> is single-use and desk-database-dependent — " \
                 "the two failure modes this recipe exists to remove"
  end

  # Reusability is not a nicety; it is why handing over the ENDPOINT beats handing
  # over a token. Drop the reason and the next editor "simplifies" it back.
  test "the recipe states both properties that make it correct" do
    assert_match(/right database, by construction/i, @body,
                 "the doc must say WHY the endpoint is right, or the reason is lost on the next edit")
    assert_match(/reusable/i, @recipe + @body[/### Why in-request.*/m].to_s,
                 "the doc must say the URL is reusable — that each click mints a fresh token")
  end

  # A CENSUS, not a context sniff. `create_magic_link` may legitimately appear in
  # this file exactly once — the table row naming the mint that lands in the wrong
  # database. Counting is the property itself; a proximity window is a proxy for
  # "this is described, not prescribed" and a fresh console recipe planted beside
  # the hazard would inherit its words and score as history.
  test "the only console mint named is the one marked as the failure" do
    found = @body.scan(/create_magic_link/)

    assert_equal 1, found.length,
                 "expected exactly one mention — the hazard row. Extra mentions mean the console " \
                 "recipe crept back; none means the hazard stopped being explained."

    row = @body[/^.*create_magic_link.*$/]
    assert_match(/shared|wrong/i, row,
                 "the one permitted mention must be marked as landing in the wrong database, " \
                 "not left looking prescriptive")
    assert_match(/302|\/login|\/signin/, row,
                 "and it must name the symptom, so the next reader recognises the bounce")
  end

  # The root operating model is auto-loaded by every session, so it outranks the
  # module for reach. It carried the same console recipe and the same stale label.
  test "the root operating model teaches the same mechanism" do
    root = ROOT_DOC.read

    assert_includes root, IN_REQUEST_MINT,
                    "docs/agents/index.md is installed to AGENTS.md/CLAUDE.md and read by every " \
                    "session — it must name the in-request mint too"
    refute_match(/create_magic_link/, root,
                 "the root doc has no room to explain the hazard, so it must not name the " \
                 "console mint at all")
    refute_match(/^Magic Link: http:\/\/localhost:<port>\/l\/<token>/, root,
                 "the pasted label must not be a pre-minted single-use token")
  end
end
