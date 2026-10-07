# frozen_string_literal: true

# Generates one round of email header candidates off the request
# (EmailImages::Build). Any error is discarded, overriding ApplicationJob's
# retry_on: a retry is a second paid call. A re-run after a restart finds its
# claim taken and spends nothing.
class EmailImageBuildJob < ApplicationJob
  queue_as :default
  discard_on StandardError

  def perform(brief_slug, started_at, count = nil, notes = nil)
    brief = EmailImageBrief.find_by(slug: brief_slug)
    return unless brief

    EmailImages::Build.run(brief, started_at: Time.iso8601(started_at), count: count, notes: notes)
  end
end
