class GithubCommitRange < ApplicationRecord
  has_many :github_builder_commit_range_caches, dependent: :destroy

  validates :week_start_date, :week_end_date, :label, presence: true
  validates :week_start_date, uniqueness: true
  validate :week_start_is_monday
  validate :week_end_is_sunday

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

    start_date = start_date.to_date
    end_date = end_date.to_date
    if start_date.year == end_date.year
      "#{start_date.strftime("%b %-d")} - #{end_date.strftime("%b %-d")}"
    else
      "#{start_date.strftime("%b %-d, %Y")} - #{end_date.strftime("%b %-d, %Y")}"
    end
  end

  private

  def normalize_week_dates
    return if week_start_date.blank?

    self.week_start_date = Github::BuilderWeeklyAggregator.week_start_for(week_start_date)
    self.week_end_date = week_start_date + 6.days
  end

  def assign_label
    self.label = self.class.label_for(week_start_date, week_end_date)
  end

  def week_start_is_monday
    return if week_start_date.blank? || week_start_date.monday?

    errors.add(:week_start_date, "must be a Monday")
  end

  def week_end_is_sunday
    return if week_end_date.blank? || week_end_date.sunday?

    errors.add(:week_end_date, "must be a Sunday")
  end
end
