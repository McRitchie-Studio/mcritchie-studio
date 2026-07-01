require "test_helper"

class AviSizerTest < ActiveSupport::TestCase
  # Build a sizer with an explicit key so #call doesn't short-circuit on the
  # keyless path; the HTTP seam (#call_api) is stubbed per test.
  def sizer_for(task, api_key: "test-key")
    Avi::Sizer.new(task).tap { |s| s.instance_variable_set(:@api_key, api_key) }
  end

  def api_response(text)
    { "content" => [{ "type" => "text", "text" => text }] }
  end

  test "maps a clean size word to that size" do
    sizer = sizer_for(tasks(:new_task))
    sizer.stub(:call_api, api_response("medium")) do
      assert_equal "medium", sizer.call
    end
  end

  test "extracts the size from a messy reply" do
    sizer = sizer_for(tasks(:new_task))
    sizer.stub(:call_api, api_response("Size: large.\n")) do
      assert_equal "large", sizer.call
    end
  end

  test "maps xl" do
    sizer = sizer_for(tasks(:new_task))
    sizer.stub(:call_api, api_response("xl")) do
      assert_equal "xl", sizer.call
    end
  end

  test "returns nil (never fabricates) when the reply has no size word" do
    sizer = sizer_for(tasks(:new_task))
    sizer.stub(:call_api, api_response("I'm honestly not sure")) do
      assert_nil sizer.call
    end
  end

  test "returns nil without calling the API when the key is unset" do
    sizer = sizer_for(tasks(:new_task), api_key: nil)
    sizer.stub(:call_api, ->(*) { raise "must not reach the API without a key" }) do
      assert_nil sizer.call
    end
  end

  test "prompt carries the task's title, kind, shape, and acceptance criteria" do
    task = tasks(:new_task)
    task.update!(metadata: { "devops" => {
      "kind" => "feature", "shape" => "backend",
      "acceptance" => ["Avi shirt sizes a designed task automatically",
                       "The job sets po size only when blank"]
    } })
    prompt = sizer_for(task).send(:user_prompt)
    assert_includes prompt, task.title
    assert_includes prompt, "backend"
    assert_includes prompt, "Avi shirt sizes a designed task automatically"
  end
end
