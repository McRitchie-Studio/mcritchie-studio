class CreateBuilders < ActiveRecord::Migration[7.2]
  def change
    change_table :people do |t|
      t.string :location
      t.string :avatar_url
      t.string :website_url
      t.string :email
      t.string :linkedin_url
      t.string :x_url
      t.string :instagram_url
      t.string :facebook_url
    end
    add_index :people, :email

    create_table :builders do |t|
      t.references :person, null: false, foreign_key: true
      t.string :github_login, null: false
      t.string :github_profile_url
      t.string :github_avatar_url
      t.string :github_name
      t.string :github_company
      t.text :github_bio
      t.string :github_blog
      t.string :github_email
      t.string :github_twitter_username
      t.string :primary_language
      t.string :source_dataset
      t.string :source_url
      t.integer :source_rank
      t.integer :source_contributions
      t.boolean :active, null: false, default: true
      t.jsonb :raw_profile, null: false, default: {}

      t.timestamps
    end
    add_index :builders, :github_login, unique: true
    add_index :builders, [:primary_language, :active]
    add_index :builders, :source_dataset
  end
end
