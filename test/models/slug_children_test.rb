require "test_helper"

# [unit] Every slug column the census resolves to a Sluggable parent is one of
# that parent's slug_children, so rename_slug! rewrites it. The foreign keys
# cascade most of them in the database as well; the declaration is what reaches
# the columns SlugCensus::UNCONSTRAINED leaves without a key.
class SlugChildrenTest < ActiveSupport::TestCase
  def census = SlugCensus.new

  def resolved_columns
    census.slug_columns.filter_map do |table, column|
      target_table, target_column, via = census.resolve(table, column)
      [table, column, target_table, target_column] unless via == :unresolved
    end
  end

  def model_for(table)
    Rails.application.eager_load!
    ApplicationRecord.descendants.find { |m| !m.abstract_class? && m.base_class == m && m.table_name == table }
  end

  test "[unit] each parent's slug_children covers every census column that targets it" do
    missing = resolved_columns.filter_map do |table, column, target_table, target_column|
      parent = model_for(target_table)
      next unless parent&.include?(Sluggable) && target_column == "slug"

      "#{table}.#{column} -> #{parent.name}" unless parent.slug_children.include?([table, column])
    end

    assert_empty missing, "declare these with has_slug_children (or a slug-keyed has_many) on the parent"
  end

  test "[unit] the census still resolves the columns this pin depends on" do
    resolved = resolved_columns.map { |table, column, *| "#{table}.#{column}" }

    %w[news.primary_person_slug contents.game_slug desk_records.app_slug athletes.team_slug artifacts.brief_slug].each do |name|
      assert_includes resolved, name
    end
  end

  test "[unit] a person rename rewrites a child the person has no association for" do
    person = Person.create!(first_name: "Slugchild", last_name: "Renamer")
    news = News.create!(title: "Slugchild renamer story", url: "https://example.com/slugchild", primary_person_slug: person.slug)

    counts = person.rename_slug!("slugchild-renamed")

    assert_equal "slugchild-renamed", news.reload.primary_person_slug
    assert counts.key?("news.primary_person_slug")
  end
end
