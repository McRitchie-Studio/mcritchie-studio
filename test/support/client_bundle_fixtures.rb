# Client-app host fixtures (docs/agents/system/client-app-host.md): a small valid
# bundle, the demo bundle on disk, and a client app holding a build task.
require_relative "client_cto_fixtures"

module ClientBundleFixtures
  include ClientCtoFixtures

  DEMO_DIR = Rails.root.join("test/fixtures/files/client_bundles/demo").to_s

  # A page on the Studio template: its content in one <main data-studio-content>
  # (the host adds the navbar and footer).
  def template_page(title, body = "")
    "<!doctype html><title>#{title}</title><main data-studio-content>#{body}</main>"
  end

  def bundle_files(**extra)
    { "index.html" => template_page("Pawsome", "<h1>Pawsome</h1>") + "<script src=\"/app.js\"></script>",
      "app.js" => "console.log('hi')",
      "assets/app-3f9a2c1b.css" => "body{color:red}",
      "about.html" => template_page("About") }.merge(extra)
  end

  # A client app (App + CTO) whose /build request holds the name and names a
  # board task in `building`: the launcher's build task.
  def client_app_with_build_task!(slug: "pawsome", task: tasks(:new_task))
    task.update_columns(stage: "building")
    AppRequest.create!(prompt: "A booking page for one groomer", subdomain: slug, status: "queued",
                       task_slug: task.slug)
    client_app!(slug: slug, name: slug.titleize)
  end
end
