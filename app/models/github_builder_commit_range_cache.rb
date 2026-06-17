class GithubBuilderCommitRangeCache < ApplicationRecord
  belongs_to :tracked_github_builder
  belongs_to :github_commit_range

  scope :for_cache_key, ->(cache_key = Github::CommitCacheKey.current) { where(cache_run_key: cache_key) }

  validates :github_login, :cohort, :cached_at, :cache_run_key, presence: true
  validates :cohort, inclusion: { in: TrackedGithubBuilder::COHORTS }
  validates :tracked_github_builder_id, uniqueness: { scope: :github_commit_range_id }

  before_validation :normalize_github_login

  private

  def normalize_github_login
    self.github_login = github_login.to_s.strip.downcase if github_login.present?
  end
end
