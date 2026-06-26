# Durable, day-granular watermark of the latest commit timestamp ingested into
# GithubCommitObservation. Observations are a staging area that gets pruned once
# fully cached (Github::BuilderHistoryBatchRunner), so the admin dashboard
# re-sources its observed-through date from this singleton when the staging table
# is empty. The weekly caches can't supply it — they're week-granular, so they
# can't tell whether the latest week was only partially collected (the partial-
# week boundary protection that GithubCommitObservation.maximum(:committed_at)
# used to provide).
class GithubObservationWindow < ApplicationRecord
  def self.instance
    first || create!
  end

  def self.observed_through_at
    instance.observed_through_at
  end

  # Monotonically raise the watermark to the newest committed_at we've ingested.
  # Called right before the batch runner prunes a builder's staged observations.
  def self.advance_to(timestamp)
    return if timestamp.blank?

    record = instance
    current = record.observed_through_at
    return current if current.present? && current >= timestamp

    record.update!(observed_through_at: timestamp)
    record.observed_through_at
  end
end
