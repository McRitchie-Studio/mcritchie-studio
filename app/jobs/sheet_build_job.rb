# frozen_string_literal: true

# Builds one character sheet off the request (Appearances::SheetBuild). Any
# error is discarded, overriding ApplicationJob's retry_on: a retry is a second
# paid call. A re-run after a restart finds its claim taken and spends nothing.
class SheetBuildJob < ApplicationJob
  queue_as :default
  discard_on StandardError

  def perform(appearance_slug, started_at, number = nil)
    look = Appearance.find_by(slug: appearance_slug)
    return unless look

    Appearances::SheetBuild.run(look, started_at: Time.iso8601(started_at), number: number)
  end
end
