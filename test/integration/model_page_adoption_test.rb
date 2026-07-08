require "test_helper"

# mcritchie-studio's adoption of studio-engine's model-page protocol. The engine
# owns Studio::ModelsController + Studio::ModelPage (unit-tested there); this
# proves the CONSUMER integration — Release is registered, the admin-only engine
# route renders THIS app's Release JSON + console command, and the
# /deployments/all "Model" link points at the engine route (admin-gated).
class ModelPageAdoptionTest < ActionDispatch::IntegrationTest
  def create_release
    Release.create!(slug: "rel-adoption-ctl", branch: "release", state: "shipped")
  end

  test "[integration] release is registered in the model-page protocol" do
    assert Studio::ModelPage.registered?("release")
  end

  test "[integration] admin model page renders this app's Release JSON and console command" do
    release = create_release
    log_in_as(users(:alex))

    get studio_model_path("release", release.slug)

    assert_response :success
    expected_cmd = %(Release.find_by(slug: "#{release.slug}"))
    assert_select "code", text: /#{Regexp.escape(expected_cmd)}/
    assert_select "button[data-copy-text=?]", expected_cmd
    assert_select "a[href=?]", studio_model_random_path("release")
    assert_select "pre" do |nodes|
      assert_match %("slug": "#{release.slug}"), nodes.first.text
    end
  end

  test "[integration] a non-admin is redirected away from the model page" do
    release = create_release
    log_in_as(users(:viewer))

    get studio_model_path("release", release.slug)

    assert_redirected_to root_path
  end

  test "[integration] an unknown record is not found" do
    log_in_as(users(:alex))

    get studio_model_path("release", "does-not-exist")

    assert_response :not_found
  end

  test "[integration] the random route redirects to a real release's model page" do
    release = create_release
    log_in_as(users(:alex))

    get studio_model_random_path("release")

    assert_redirected_to studio_model_path("release", release.slug)
  end

  test "[integration] the Model link renders on /deployments/all for an admin" do
    release = create_release
    log_in_as(users(:alex))

    get all_deployments_path

    assert_response :success
    assert_select "a[href=?]", studio_model_path("release", release.slug), text: "Model"
  end

  test "[integration] the Model link is hidden from logged-out visitors" do
    create_release

    get all_deployments_path

    assert_response :success
    assert_select "a", text: "Model", count: 0
  end
end
