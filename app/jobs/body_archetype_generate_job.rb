# frozen_string_literal: true

# Generates one body archetype's image off the request (BodyArchetypes::Generate).
# Any error is discarded, overriding ApplicationJob's retry_on: a retry is a second
# paid image. A re-run after a restart finds its claim taken and spends nothing.
class BodyArchetypeGenerateJob < ApplicationJob
  queue_as :default
  discard_on StandardError

  def perform(archetype_slug, started_at)
    archetype = BodyArchetype.find_by(slug: archetype_slug)
    return unless archetype

    BodyArchetypes::Generate.run(archetype, started_at: Time.iso8601(started_at))
  end
end
