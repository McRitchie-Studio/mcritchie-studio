require "test_helper"
require "rake"

# [integration] contacts:import_cyvasse_traits (task contact-traits-from-cyvasse):
# the rake task reads the CSV file the production pipe writes, stores the
# traits, and prints counts only — never a player's email or username.
class ImportCyvasseTraitsTaskTest < ActiveSupport::TestCase
  TASK = "contacts:import_cyvasse_traits".freeze

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?(TASK)
    Rake::Task[TASK].reenable
    @contact = Contact.create!(email: "vey@example.com", tags: %w[cyvasse-legacy])
    @file = Tempfile.new([ "cyvasse-traits", ".csv" ])
    @file.write("#{Contacts::CyvasseTraitsImport::HEADERS.join(",")}\n" \
                "Vey@example.com,veyjin,27,25,20,7,2014-03-02,2026-09-01,12,2026-09-30T12:00:00Z\n" \
                "nobody@example.com,ghost,1,1,0,1,2015-01-01,2015-01-02,,2026-09-30T12:00:00Z\n")
    @file.flush
  end

  teardown { @file.close! }

  test "stores the traits and prints counts, never a row" do
    out, = capture_io { Rake::Task[TASK].invoke(@file.path) }

    assert_equal 27, @contact.reload.cyvasse_games
    assert_match(/2 rows .*1 matched a contact, 1 did not; 1 updated/, out)
    assert_match(/with Cyvasse games now: 1 contacts/, out)
    assert_no_match(/vey|veyjin|nobody|ghost/i, out)
  end
end
