class AddMascotToTeams < ActiveRecord::Migration[7.2]
  class TeamRecord < ActiveRecord::Base
    self.table_name = "teams"
  end

  def up
    add_column :teams, :mascot, :string

    TeamRecord.reset_column_information
    TeamRecord.find_each do |team|
      mascot = derived_mascot(team.name, team.location)
      team.update_columns(mascot: mascot) if mascot.present?
    end
  end

  def down
    remove_column :teams, :mascot
  end

  private

  def derived_mascot(name, location)
    name = name.to_s.strip
    location = location.to_s.strip
    return name if name.blank? || location.blank?

    name.sub(/\A#{Regexp.escape(location)}\s*/, "").strip.presence || name
  end
end
