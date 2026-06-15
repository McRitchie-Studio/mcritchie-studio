class TrackedGithubBuilderRepo < ApplicationRecord
  belongs_to :tracked_github_builder

  scope :active, -> { where(active: true) }

  validates :repo_full_name, presence: true,
    uniqueness: { scope: :tracked_github_builder_id },
    format: { with: /\A[^\/\s]+\/[^\/\s]+\z/ }

  before_validation :normalize_repo_full_name

  private

  def normalize_repo_full_name
    self.repo_full_name = repo_full_name.to_s.strip if repo_full_name.present?
  end
end
