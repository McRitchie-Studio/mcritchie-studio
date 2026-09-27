# THE 1000-FOOT VIEW OF EVERY CHARACTER MODEL IN FLIGHT — five lanes, drag to move.
#
# The operator's ask, his words (2026-09-26): "I want to turn the model creation for
# person to a similar swim lane to /deployments that way I can watch the model go
# through the steps … This will help me get a 1000 ft view of the models being
# generated." So this is an OPERATIONS surface over the whole library, which is why it
# is a top-level board rather than another panel on the person page: the question it
# answers is about the set, and AppearancesController answers the questions about one
# look.
#
# ── DRAGGING A CARD TRIGGERS NOTHING, AND THAT IS ENFORCED HERE ───────────────────
#
# His instruction, verbatim: "No nothing triggers yet, I would rather just not remove
# it." Two instructions in one sentence — keep the drag, wire it to no side effect —
# and #update is the whole of the second. It writes ONE column, on ONE row, and calls
# nothing: no search, no vision classification, no character-identity mint, no image
# generation, no job enqueued. A board that spent money when a card was dragged would
# be the worst version of this feature, and the three paths that DO spend are the three
# admin-gated POSTs on AppearancesController, reached from the card's own link.
#
# `#reorder` comes from Studio::Board::Reorderable and is the same promise: it restamps
# `position` with 100-gaps and returns `{ success: true }`.
#
# ── WHY A BACKWARD DRAG IS REFUSED ────────────────────────────────────────────────
#
# The lane a card renders in is DERIVED from evidence (Appearances::LookReading), and
# a hand placement is honoured only FORWARD of it. Dragging a look with a delivered
# character sheet back to Defined would make the board claim finished work was not
# done, so this refuses that drag with the reason, and the board primitive reverts the
# card and toasts the sentence. Accepting it and correcting it on the next page load
# was the alternative, and it is worse: a silent correction teaches the operator that
# the board eats his input.
#
# ── THE READ IS PUBLIC, EVERY WRITE IS ADMIN ──────────────────────────────────────
#
# #index reads rows and renders — it spends nothing, and it shows the same facts the
# person page and the model page already show without a session. That matches
# ContentsController and TasksController, whose boards are public reads beside
# admin-gated writes. The two writes here are admin-gated because they are writes, and
# because a session costs a member of the public one email address (hub signup is
# open) and is therefore no control at all.
class ModelPipelineController < ApplicationController
  # The `reorder` action, its `slugs` guard, the 100-gap restamp (delegated to
  # Appearance's Studio::Board::Rankable#reposition!) and the ErrorLog-logging + 422
  # net all come from the shared board concern. The board POSTs { slugs: [...],
  # zone: "<stage>" } and the action reads only `slugs`.
  include Studio::Board::Reorderable
  board_reorderable model: Appearance, id_attr: :slug, param: :slugs

  skip_before_action :verify_authenticity_token, if: -> { request.format.json? }
  skip_before_action :require_authentication, only: [:index]
  before_action :require_admin, except: [:index]

  def index
    @board = Appearances::Pipeline.build
  end

  # PATCH — record the operator's hand placement. The board primitive sends
  # `{ appearance: { stage: "<lane>" } }` for a cross-lane drop.
  #
  # THE REFUSAL IS COMPUTED FROM THE LOOK'S OWN EVIDENCE, through the same reading the
  # board rendered with, so the sentence the operator gets names the fact that blocked
  # him rather than a rule number.
  def update
    look = Appearance.live.find_by!(slug: params[:slug])
    target = params.require(:appearance).permit(:stage)[:stage].to_s
    reading = Appearances::Pipeline.reading_for(look)

    unless reading.placeable?(target)
      return render json: { error: refusal_for(reading, target) }, status: :unprocessable_entity
    end

    # THE ONLY WRITE. `update!` on one column, nothing after it.
    rescue_and_log(target: look) { look.update!(stage: target) }
    render json: { success: true, slug: look.slug, stage: look.stage }
  rescue ActiveRecord::RecordNotFound
    render json: { error: "That model is not on the board any more — reload and try again." },
           status: :not_found
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  # WHY THE DRAG WAS REFUSED, in the operator's terms: the lane the evidence puts it in,
  # the evidence itself, and the rule. A message that only said "not allowed" would send
  # him to read this file.
  #
  # KEPT SHORT BECAUSE IT IS A TOAST. The board primitive renders the server's sentence in
  # a fixed chip at the top of the viewport; measured in a browser, a version that also
  # repeated the card's title ran the full width of a 1440px window and was clipped by the
  # dev banner. The operator just dragged the card — he knows which one it was.
  def refusal_for(reading, target)
    if Appearances::LookReading.index(target).nil?
      return "#{target.presence || 'That'} is not one of the five lanes."
    end

    "Stays in #{Appearances::LookReading::LABELS.fetch(reading.derived_stage)} — " \
      "#{reading.blocker} A card moves forward of its evidence, never behind it."
  end
end
