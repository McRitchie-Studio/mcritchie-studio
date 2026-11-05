require "test_helper"
require "rake"

# [unit] The release's post_deploy_cmd, `bin/rails apps:seed apps:seed_owners`: it
# writes the catalog's App rows and the owners, it is safe to run twice, and it exits
# non-zero on a row it could not make, so a green hook means the owners landed.
class AppsRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("apps:seed_owners")
  end

  # The task's stdout; an abort's SystemExit is re-raised after the capture.
  def run_task(name)
    Rake::Task[name].reenable
    exited = nil
    out, = capture_io do
      Rake::Task[name].invoke
    rescue SystemExit => e
      exited = e
    end
    raise exited if exited

    out
  end

  test "apps:seed writes the voicebox row from the catalog, under the catalog's name" do
    refute App.exists?(slug: "voicebox"), "control: the fixtures hold no voicebox row"

    run_task("apps:seed")

    entry = AppCatalog.app("voicebox")
    row = App.find_by!(slug: "voicebox")
    assert_equal "Voicebox", row.name
    assert_equal [ entry.emoji, entry.color, entry.status ], [ row.emoji, row.color, row.status ]
    assert_equal AppCatalog.seed_rows.size, App.where(slug: AppCatalog.seed_rows.map { |seed| seed[:slug] }).count
  end

  test "apps:seed_owners after apps:seed gives the hub owner alex-build and voicebox, and repeats safely" do
    hub_owner = users(:alex)
    hub_owner.save!
    assert_equal "alex@mcritchie.studio", hub_owner.email
    run_task("apps:seed")

    run_task("apps:seed_owners")
    assert_equal %w[alex-build mcritchie-studio voicebox],
                 AppMembership.owners.where(user_slug: hub_owner.slug).order(:app_slug).pluck(:app_slug)
    count = AppMembership.count

    run_task("apps:seed")
    run_task("apps:seed_owners")
    assert_equal count, AppMembership.count
  end

  test "apps:seed_owners exits non-zero when the row is missing" do
    refute App.exists?(slug: "voicebox"), "control: the seed has not run"

    error = assert_raises(SystemExit) { run_task("apps:seed_owners") }

    refute error.success?
  end

  test "apps:seed_owners exits zero when only another owner's user is missing, as on QA" do
    run_task("apps:seed")
    User.where("LOWER(email) = ?", "alex@turfmonster.media").destroy_all

    out = run_task("apps:seed_owners")

    assert_includes out, "App owner: turf-monster no user"
    assert_includes out, "App owner: voicebox created"
  end
end
