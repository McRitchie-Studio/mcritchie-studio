# THE BODY ARCHETYPES — the reusable body-build references a player sheet is drawn
# to (BodyArchetype). Admin only, the page included, like the look page that points
# at them.
#
# #generate SPENDS MONEY: one GPT-5 image per press, enqueued
# (BodyArchetypes::Generate). Nothing else here, and nothing in a migration or
# seed, ever generates one.
class BodyArchetypesController < ApplicationController
  before_action :require_admin

  def index
    @archetypes = BodyArchetype.ordered.to_a
    @generator_row = BodyArchetypes::Generate.row
    @look_counts = Appearance.where(body_archetype_slug: @archetypes.map(&:slug)).group(:body_archetype_slug).count
  end

  def generate
    archetype = BodyArchetype.find_by!(slug: params[:slug])
    rescue_and_log(target: archetype) { start(archetype) }
  rescue StandardError => e
    redirect_to body_archetypes_path, alert: "Could not start the archetype image: #{e.message}"
  end

  private

  # The expected refusals (no generator, already generating) are states, not
  # failures, so they answer here and leave no ErrorLog row.
  def start(archetype)
    BodyArchetypes::Generate.start!(archetype)
    redirect_to body_archetypes_path, notice: "#{archetype.name}: #{BodyArchetypes::Generate::STARTED_NOTICE}"
  rescue BodyArchetypes::Generate::Refused => e
    redirect_to body_archetypes_path, alert: e.message
  end
end
