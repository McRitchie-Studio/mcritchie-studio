# A client app's CTO, as data (.agents/epics/build-with-xan-design.md; docs:
# docs/agents/system/client-cto.md). One row per client app, made by AppLaunch from
# the /build intake. ONE soul, `client_cto`, answers every client app's web chat;
# this row picks its voice: the name and portrait the client chose, the palette,
# and the app's facts and plan, which the persona template
# (docs/agents/agents/client_cto/persona.md) is filled from.
#
# Our own CTOs (Avi, Turf, Tyrion) are souls on disk in config/cto_reports.yml
# and have no row here; AppOwnership.cto_for_app asks that file first.
#
# TRUST. Every field but app_slug was written by the client. The persona the
# dispatcher builds from it (#persona_json, through AgentMessages::MemoryBundle)
# is laid out INSIDE the prompt's untrusted fence, never as rules
# (AgentMailbox::ContextBuilder#client_persona_layer).
class AppCto < ApplicationRecord
  SOUL = "client_cto".freeze
  NAME_LIMIT = 40
  PLAN_LIMIT = 2000
  # A default portrait is a public asset path; anything else is an Active
  # Storage blob key (an uploaded portrait). Nothing else renders.
  PORTRAIT_PATH = %r{\A/[a-z0-9/_-]+\.(?:webp|png|jpe?g|svg)\z}

  belongs_to :app, foreign_key: :app_slug, primary_key: :slug, inverse_of: :client_cto

  validates :app_slug, presence: true, uniqueness: true
  validates :name, presence: true, length: { maximum: NAME_LIMIT }
  validates :plan, length: { maximum: PLAN_LIMIT }
  validate :palette_is_complete

  before_validation -> { self.name = name.to_s.squish.presence }

  # The `client_cto` rows for these app slugs, keyed by slug: one query for a list page.
  def self.for_apps(slugs) = where(app_slug: Array(slugs).map(&:to_s)).index_by(&:app_slug)

  # The portrait to render: a default's public path, an uploaded blob, or nil
  # (the page shows the emoji fallback).
  def portrait_path = portrait.to_s.match?(PORTRAIT_PATH) ? portrait : nil

  def portrait_blob
    return nil if portrait.blank? || portrait_path

    ActiveStorage::Blob.find_by(key: portrait)
  end

  def light = AppPalette.side(palette, "light")
  def dark = AppPalette.side(palette, "dark")

  # What the persona template is filled with (MemoryBundle "persona"). Plain
  # data; the dispatcher fences it.
  def persona_json
    {
      "soul" => SOUL,
      "name" => name,
      "app_slug" => app_slug,
      "app_name" => app&.name,
      "host" => "#{app_slug}.#{AppRequest::PARENT_DOMAIN}",
      "palette" => AppPalette.normalize(palette),
      "plan" => plan.to_s,
      "facts" => facts.is_a?(Hash) ? facts : {}
    }
  end

  private

  def palette_is_complete
    AppPalette.errors(palette).each { |message| errors.add(:palette, message) }
  end
end
