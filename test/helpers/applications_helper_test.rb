require "test_helper"

# [unit] ApplicationsHelper#app_todos_path: a click on /applications goes to the
# app's pipeline (its todos and steps), except where the pipeline would 404.
class ApplicationsHelperTest < ActionView::TestCase
  test "[unit] an app clicks through to its pipeline; an owner of an unannounced app to its page" do
    welding = App.new(slug: "commercial-welding")
    assert_equal "/applications/commercial-welding", app_todos_path(welding, admin: false)
    assert_equal "/applications/commercial-welding/pipeline", app_todos_path(welding, admin: true)
    assert_equal "/applications/pawsome/pipeline", app_todos_path(App.new(slug: "pawsome"), admin: false)
  end
end
