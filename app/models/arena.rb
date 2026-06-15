class Arena < ApplicationRecord
  include Sluggable

  has_many :home_teams, class_name: "Team", foreign_key: :home_arena_slug, primary_key: :slug

  validates :name, presence: true

  def name_slug
    name.parameterize
  end
end
