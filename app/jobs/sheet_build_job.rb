# frozen_string_literal: true

# Builds one character sheet off the request (Appearances::SheetBuild). The
# outcome lands on the look; this job never raises, so it is never retried
# into a second paid call.
class SheetBuildJob < ApplicationJob
  queue_as :default

  def perform(appearance_slug, started_at, number = nil)
    look = Appearance.find_by(slug: appearance_slug)
    return unless look

    Appearances::SheetBuild.run(look, started_at: Time.iso8601(started_at), number: number)
  end
end
