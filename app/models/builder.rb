class Builder < ApplicationRecord
  belongs_to :person

  scope :active, -> { where(active: true) }
  scope :ruby, -> { where(primary_language: "Ruby") }

  validates :github_login, presence: true, uniqueness: true,
    format: { with: /\A[a-z0-9](?:[a-z0-9-]{0,37}[a-z0-9])?\z/i }

  before_validation :normalize_github_login

  def display_name
    github_name.presence || person&.full_name.presence || github_login
  end

  def github_url
    github_profile_url.presence || "https://github.com/#{github_login}"
  end

  def avatar_url
    person&.avatar_url.presence || github_avatar_url
  end

  def tracked_github_builder
    TrackedGithubBuilder.find_by(github_login: github_login)
  end

  private

  def normalize_github_login
    self.github_login = github_login.to_s.strip.downcase if github_login.present?
  end
end
