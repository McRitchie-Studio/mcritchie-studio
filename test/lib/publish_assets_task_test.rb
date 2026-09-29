require "test_helper"
require "rake"

# [unit] broadcasts:publish_assets skips on QA, which has no AWS credentials
# (the release runs post-deploys there first), and publishes everywhere else.
class PublishAssetsTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("broadcasts:publish_assets")
    @task = Rake::Task["broadcasts:publish_assets"]
  end

  def run_task
    @task.reenable
    capture_io { @task.invoke }.first
  end

  test "on QA it skips without touching S3" do
    Studio.stub(:qa_environment?, true) do
      Broadcasts::Assets.stub(:publish_all!, -> { flunk "published on QA" }) do
        assert_match "QA: skipping broadcast asset publish", run_task
      end
    end
  end

  test "off QA it publishes" do
    Studio.stub(:qa_environment?, false) do
      Broadcasts::Assets.stub(:publish_all!, { "a.jpg" => "https://s3.example/email/a.jpg" }) do
        Broadcasts::Assets.stub(:base_url, "https://s3.example/email") do
          assert_match "Published 1 asset(s)", run_task
        end
      end
    end
  end
end
