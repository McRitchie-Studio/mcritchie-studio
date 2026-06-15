class TrackedGithubBuilder < ApplicationRecord
  COHORTS = %w[ai_builder control_builder].freeze

  has_many :tracked_github_builder_repos, dependent: :destroy
  has_many :github_builder_commit_range_caches, dependent: :destroy

  scope :active, -> { where(active: true) }
  scope :ai_builders, -> { where(cohort: "ai_builder") }
  scope :control_builders, -> { where(cohort: "control_builder") }

  validates :github_login, presence: true, uniqueness: true,
    format: { with: /\A[a-z0-9](?:[a-z0-9-]{0,37}[a-z0-9])?\z/i }
  validates :cohort, presence: true, inclusion: { in: COHORTS }

  before_validation :normalize_github_login

  def active_repos
    tracked_github_builder_repos.active
  end

  def display_label
    display_name.presence || github_login
  end

  def current_week_commits(fetcher: Github::CommitFetcher.new, aggregator: Github::BuilderWeeklyAggregator.new, today: Github::CommitFetchWindows.utc_today)
    fetch_commits_for_window(Github::CommitFetchWindows.current_week(today: today), fetcher: fetcher, aggregator: aggregator)
  end

  def last_week_commits(fetcher: Github::CommitFetcher.new, aggregator: Github::BuilderWeeklyAggregator.new, today: Github::CommitFetchWindows.utc_today)
    fetch_commits_for_window(Github::CommitFetchWindows.last_week(today: today), fetcher: fetcher, aggregator: aggregator)
  end

  def last_year_commits(fetcher: Github::CommitFetcher.new, aggregator: Github::BuilderWeeklyAggregator.new, today: Github::CommitFetchWindows.utc_today)
    fetch_commits_for_window(Github::CommitFetchWindows.last_year(today: today), fetcher: fetcher, aggregator: aggregator)
  end

  def last_five_commits(fetcher: Github::CommitFetcher.new, aggregator: Github::BuilderWeeklyAggregator.new, today: Github::CommitFetchWindows.utc_today)
    fetch_commits_for_window(Github::CommitFetchWindows.last_five_years(today: today), fetcher: fetcher, aggregator: aggregator)
  end
  alias_method :last_five_years_commits, :last_five_commits

  def self.current_week_commits(github_login, **options)
    find_by!(github_login: normalize_login_value(github_login)).current_week_commits(**options)
  end

  def self.last_week_commits(github_login, **options)
    find_by!(github_login: normalize_login_value(github_login)).last_week_commits(**options)
  end

  def self.last_year_commits(github_login, **options)
    find_by!(github_login: normalize_login_value(github_login)).last_year_commits(**options)
  end

  def self.last_five_commits(github_login, **options)
    find_by!(github_login: normalize_login_value(github_login)).last_five_commits(**options)
  end
  class << self
    alias_method :last_five_years_commits, :last_five_commits
  end

  def self.normalize_login_value(github_login)
    github_login.to_s.strip.downcase
  end

  private

  def fetch_commits_for_window(window, fetcher:, aggregator:)
    segment_cache = lambda do |segment_start, segment_end|
      aggregator.aggregate!(start_date: segment_start, end_date: segment_end, github_logins: github_login)
    end
    result = fetcher.fetch_for_builder(
      builder: self,
      start_date: window.begin,
      end_date: window.end,
      after_segment: segment_cache
    )
    aggregator.aggregate!(start_date: window.begin, end_date: window.end, github_logins: github_login)
    result
  end

  def normalize_github_login
    self.github_login = github_login.to_s.strip.downcase if github_login.present?
  end
end
