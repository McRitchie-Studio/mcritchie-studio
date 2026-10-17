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
    assert_equal [ "Nova", "pawsome", "Pawsome", "pawsome.mcritchie.studio" ],
                 persona.values_at("name", "app_slug", "app_name", "host")
    assert_equal PALETTE, persona["palette"]
    assert_equal ANSWERS["plan"], persona["plan"]
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

  test "a portrait renders from a public path or an uploaded blob, never anything else" do
    cto = client_app!.client_cto
    assert_equal "/build/portraits/portrait-03.webp", cto.portrait_path

    cto.portrait = "javascript:alert(1)"
    assert_nil cto.portrait_path
    assert_nil cto.portrait_blob, "an unknown key is no blob"

    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("png"), filename: "me.png", key: "intake/tok/me.png")
    cto.portrait = blob.key
    assert_equal blob, cto.portrait_blob
  end

  test "deleting the app deletes its CTO" do
    app = client_app!
    app.destroy!
    assert_equal 0, AppCto.where(app_slug: "pawsome").count
  end
end
