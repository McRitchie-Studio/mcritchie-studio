class CreateGithubObservationWindows < ActiveRecord::Migration[7.2]
  def change
    create_table :github_observation_windows do |t|
      t.datetime :observed_through_at

      t.timestamps
    end
  end
end
