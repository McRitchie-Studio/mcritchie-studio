class GithubCommitRange < ApplicationRecord
  has_many :github_builder_commit_range_caches, dependent: :destroy

  validates :week_start_date, :week_end_date, :label, presence: true
  validates :week_start_date, uniqueness: true
  validate :week_start_is_saturday
  validate :week_end_is_friday

  before_validation :normalize_week_dates
  before_validation :assign_label

  scope :recent, -> { order(week_start_date: :desc) }

  def self.for_week_start(value)
    week_start = Github::BuilderWeeklyAggregator.week_start_for(value)
    find_or_create_by!(week_start_date: week_start)
  end

  def display_label
    label.presence || self.class.label_for(week_start_date, week_end_date)
  end

  def self.label_for(start_date, end_date)
    return "" if start_date.blank? || end_date.blank?

    end_date = end_date.to_date
    end_date.strftime("%b %-d, %Y")
  end

  private

  def normalize_week_dates
    return if week_start_date.blank?

    self.week_start_date = Github::BuilderWeeklyAggregator.week_start_for(week_start_date)
    self.week_end_date = week_start_date + (Github::BuilderWeeklyAggregator::WEEK_LENGTH_DAYS - 1).days
  end

  def assign_label
    self.label = self.class.label_for(week_start_date, week_end_date)
  end

  def week_start_is_saturday
    return if week_start_date.blank? || week_start_date.saturday?

    errors.add(:week_start_date, "must be a Saturday")
  end

  def week_end_is_friday
    return if week_end_date.blank? || week_end_date.friday?

    errors.add(:week_end_date, "must be a Friday")
  end
end
