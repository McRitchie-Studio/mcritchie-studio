require "test_helper"

# The scheduled half of /tasks/insights-doc-never-regenerated. What matters is not
# that the job runs but that a stale artefact leaves a RECEIPT — before this, a doc
# that had stopped tracking the bank said nothing to anyone, anywhere.
class InsightsDocFreshnessJobTest < ActiveSupport::TestCase
  def with_doc(markdown)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "insights.md")
      File.write(path, markdown)
      Insights::DocGenerator.stub(:default_path, Pathname.new(path)) { yield }
    end
  end

  def rendered(count:, at: Time.current)
    rows = Array.new(count) { |i| { slug: "lesson #{i}", disposition: "good" } }
    Insights::DocGenerator.render(insights: rows, generated_at: at)
  end

  def banked(slug:)
    action = AgentAction.capture(session_id: "job-#{slug.object_id}", kind: "edit", outcome: "ok")
    ActionGrade.create!(agent_action: action, grader: "alex", slug: slug, disposition: "good").bank!
  end

  test "[integration] a stale doc writes an ErrorLog receipt naming the drift" do
    banked(slug: "a banked lesson")

    with_doc(rendered(count: 0)) do
      assert_difference -> { ErrorLog.count }, 1 do
        InsightsDocFreshnessJob.perform_now
      end
    end

    log = ErrorLog.order(:id).last
    assert_match(/StaleDocError/, log.inspect_field,
                 "the receipt must name the failure class, so /admin/error_logs triages it like " \
                 "any other incident")
    assert_match(/records 0 banked insights/, log.message)
    assert_match(/bank holds 1/, log.message)
    assert_equal "count_drift", log.target_name
    assert log.backtrace.present?, "the receipt carries a backtrace pointing at the job"
  end

  test "[integration] a fresh doc is quiet" do
    banked(slug: "a banked lesson")

    with_doc(rendered(count: 1)) do
      assert_no_difference -> { ErrorLog.count } do
        InsightsDocFreshnessJob.perform_now
      end
    end
  end

  # Backend discipline: the detector is best-effort. A failure inside it must be
  # captured, not raised — ApplicationJob retries StandardError three times, and a
  # persistent read bug would otherwise storm the queue every week.
  test "[integration] a failure inside the check is captured, never raised" do
    Insights::DocFreshness.stub(:check, ->(*) { raise "bank read exploded" }) do
      assert_difference -> { ErrorLog.count }, 1 do
        assert_nothing_raised { InsightsDocFreshnessJob.perform_now }
      end
    end

    assert_match(/bank read exploded/, ErrorLog.order(:id).last.message)
  end
end
