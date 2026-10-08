class SkillAssignment < ApplicationRecord
  self.ignored_columns += DeadColumns.for(table_name)
  belongs_to :agent, foreign_key: :agent_slug, primary_key: :slug
  belongs_to :skill, foreign_key: :skill_slug, primary_key: :slug

  validates :agent_slug, uniqueness: { scope: :skill_slug }
end
