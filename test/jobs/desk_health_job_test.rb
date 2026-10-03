require "test_helper"

# DeskHealthJob — the daily watch on the team@ inbound path. What matters is
# the RECEIPT: from 2026-09-29 to 2026-10-02 the MX was gone and nothing said so.
class DeskHealthJobTest < ActiveSupport::TestCase
  FakeHealth = Struct.new(:result, :error) do
    def check
      raise error if error

      result
    end
  end

  def result(failures) = DeskCapture::Health::Result.new(failures: failures, notes: [])

  test "[integration] a failed check writes an ErrorLog receipt naming every failure" do
    health = FakeHealth.new(result([ "MX in.mcritchie.studio does not route", "ingest dropped 1" ]))

    assert_difference -> { ErrorLog.count }, 1 do
      DeskHealthJob.perform_now(health: health)
    end

    log = ErrorLog.order(:id).last
    assert_match(/HealthError/, log.inspect_field)
    assert_match(/MX in.mcritchie.studio does not route \| ingest dropped 1/, log.message)
    assert_equal "desk-health", log.target_name
  end

  test "[integration] a healthy check is quiet" do
    assert_no_difference -> { ErrorLog.count } do
      DeskHealthJob.perform_now(health: FakeHealth.new(result([])))
    end
  end

  test "[unit] a crash inside the check is logged, never re-raised" do
    assert_difference -> { ErrorLog.count }, 1 do
      DeskHealthJob.perform_now(health: FakeHealth.new(nil, RuntimeError.new("boom")))
    end
  end

  test "[unit] the watch stands down on QA" do
    assert_no_difference -> { ErrorLog.count } do
      Studio.stub(:qa_environment?, true) do
        DeskHealthJob.perform_now(health: FakeHealth.new(result([ "MX gone" ])))
      end
    end
  end

  test "[unit] it is scheduled daily in production" do
    entry = YAML.load_file(Rails.root.join("config/recurring.yml")).dig("production", "desk_health")

    assert_equal "DeskHealthJob", entry["class"]
    assert_match(/\A0 7 \* \* \*/, entry["schedule"])
  end
end
