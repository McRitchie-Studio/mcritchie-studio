require "test_helper"
require "rake"

# [unit] SlugCensus (task slug-orphan-census-report): resolves every *_slug
# column to a target table or names it unresolved, counts orphan rows on
# fixtures with dangling slugs, withholds personal samples, and runs read-only:
# measured over a full run, every statement is a SELECT, none opens a
# transaction, and all of them execute while writes are prevented.
class SlugCensusTest < ActiveSupport::TestCase
  setup do
    # Orphans cannot be written under the slug foreign keys, so the keys on the
    # three columns this test dangles come off first. DDL is transactional in
    # Postgres: the test's rollback puts them back.
    connection = ActiveRecord::Base.connection
    connection.remove_foreign_key(:skill_assignments, :skills, column: :skill_slug)
    connection.remove_foreign_key(:skill_assignments, :agents, column: :agent_slug)
    connection.remove_foreign_key(:athletes, :people, column: :person_slug)
    now = Time.current
    SkillAssignment.insert_all!([
      { agent_slug: agents(:xan_agent).slug, skill_slug: "no-such-skill", created_at: now, updated_at: now },
      { agent_slug: "no-such-agent", skill_slug: "also-no-such-skill", created_at: now, updated_at: now }
    ])
    Athlete.insert_all!([ { slug: "orphan-athlete", person_slug: "no-such-person", sport: "football", created_at: now, updated_at: now } ])
  end

  def census_rows
    @census_rows ||= SlugCensus.new.run.index_by(&:name)
  end

  test "resolves every *_slug column to a target table or names it unresolved" do
    connection = ActiveRecord::Base.connection
    expected = connection.tables.flat_map { |t| connection.columns(t).map(&:name).grep(/_slug\z/).map { |c| "#{t}.#{c}" } }

    assert_operator expected.size, :>, 50, "the schema should carry dozens of *_slug columns"
    assert_equal expected.sort, census_rows.keys.sort
    census_rows.each_value do |row|
      assert_includes %i[belongs_to convention unresolved], row.via, row.name
      next unless row.resolved?

      assert connection.column_exists?(row.target_table, row.target_column), "#{row.name} -> #{row.target}"
    end

    assert_equal [ "skills.slug", :belongs_to ], census_rows["skill_assignments.skill_slug"].then { [ _1.target, _1.via ] }
    assert_equal [ "teams.slug", :belongs_to ], census_rows["contents.rival_team_slug"].then { [ _1.target, _1.via ] }
    assert_equal [ "teams.slug", :convention ], census_rows["news.primary_team_slug"].then { [ _1.target, _1.via ] }
    assert_equal [ "unresolved", :unresolved ], census_rows["tasks.epic_slug"].then { [ _1.target, _1.via ] }
    assert_nil census_rows["tasks.epic_slug"].orphans
  end

  test "counts orphans correctly on fixtures with a dangling slug" do
    skill = census_rows["skill_assignments.skill_slug"]
    assert_equal SkillAssignment.count, skill.total
    assert_equal 2, skill.orphans
    assert_equal %w[also-no-such-skill no-such-skill], skill.samples

    agent = census_rows["skill_assignments.agent_slug"]
    assert_equal 1, agent.orphans
    assert_equal %w[no-such-agent], agent.samples

    assert_equal 0, census_rows["athletes.team_slug"].orphans, "NULL slugs are not orphans"
    assert_operator census_rows["athletes.team_slug"].filled, :<, census_rows["athletes.team_slug"].total
  end

  test "withholds sample values for targets that hold people" do
    person = census_rows["athletes.person_slug"]
    assert_equal 1, person.orphans
    assert_empty person.samples
    assert person.samples_withheld

    table = SlugCensus.to_markdown([ person ])
    assert_includes table, "withheld (personal)"
    refute_includes table, "no-such-person"
  end

  test "a full run is read-only: SELECTs only, no transaction, writes prevented throughout" do
    events = []
    callback = lambda do |*, payload|
      events << [ payload[:sql], ActiveRecord::Base.current_preventing_writes ] unless payload[:name] == "CACHE"
    end
    rows = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { SlugCensus.new.run }

    assert_operator rows.size, :>, 50
    assert_operator events.size, :>=, rows.size, "the census must actually query"
    offenders = events.map(&:first).reject { |sql| sql.lstrip.match?(/\ASELECT\b/i) }
    assert_empty offenders, "every census statement must be a SELECT"
    assert events.all?(&:last), "every statement must run inside while_preventing_writes"
  end

  test "db:slug_census prints the table and a summary" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("db:slug_census")
    Rake::Task["db:slug_census"].reenable
    out, = capture_io { Rake::Task["db:slug_census"].invoke }

    assert_includes out, "| `skill_assignments.skill_slug` | skills.slug | belongs_to |"
    assert_match(/^columns: \d+ · resolved: \d+ · unresolved: \d+ · clean: \d+ · with orphans: \d+ · orphan rows: \d+$/, out)
    refute_includes out, "no-such-person"
  end
end
