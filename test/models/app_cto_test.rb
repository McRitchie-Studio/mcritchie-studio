require "test_helper"
require_relative "../support/client_cto_fixtures"

# [unit] AppCto: a client app's CTO as data, one row per app, whose persona
# fills the client_cto template (name, palette, plan, facts).
class AppCtoTest < ActiveSupport::TestCase
  include ClientCtoFixtures

  test "the persona carries the name, the app, its address, the palette and the plan" do
    cto = client_app!.client_cto
    persona = cto.persona_json

    assert_equal "client_cto", persona["soul"]
    assert_equal [ "Nova", "pawsome", "Pawsome", "pawsome.mcritchie.app" ],
                 persona.values_at("name", "app_slug", "app_name", "host")
    assert_equal PALETTE, persona["palette"]
    assert_equal PLAN, persona["plan"]
    assert_equal "Pat", persona.dig("facts", "owner")
  end

  test "one CTO per app; a name, a readable palette and a bounded name are required" do
    app = client_app!
    dup = AppCto.new(app: app, name: "Other", palette: PALETTE)
    refute dup.valid?
    assert_includes dup.errors[:app_slug], "has already been taken"

    other = App.create!(slug: "other-app", name: "Other")
    refute AppCto.new(app: other, name: " ", palette: PALETTE).valid?
    refute AppCto.new(app: other, name: "x" * 41, palette: PALETTE).valid?
    bad = AppCto.new(app: other, name: "Nova", palette: { "light" => PALETTE["light"] })
    refute bad.valid?
    assert_match(/dark needs/, bad.errors[:palette].join)
  end

  test "a portrait renders from a default portrait key, never from an upload ref or anything else" do
    cto = client_app!.client_cto
    assert_equal "cto_portraits/harbor.svg", cto.portrait_asset

    [ "javascript:alert(1)", "../../etc/passwd", "upload:abcdefgh12", "", nil ].each do |value|
      cto.portrait = value
      assert_nil cto.portrait_asset, value.inspect
    end
  end

  test "deleting the app deletes its CTO" do
    app = client_app!
    app.destroy!
    assert_equal 0, AppCto.where(app_slug: "pawsome").count
  end

  # Task build-sign-in-modal: the app's initial load.
  test "[unit] the initial load is off by default and taken once, by one caller" do
    cto = client_app!.client_cto
    assert_not cto.launch_animation_pending?, "an app made without a launch has had its first visit"
    assert_not cto.take_launch_animation!

    cto.update!(launch_animation_pending: true)
    racer = AppCto.find(cto.id)
    assert cto.take_launch_animation!, "the first visit takes it"
    assert_not cto.launch_animation_pending?
    assert_not cto.changed?, "the in-memory row matches the database"
    assert_not racer.take_launch_animation!, "a second tab holding a stale row does not play it again"
    assert_not cto.reload.launch_animation_pending?
  end
end
