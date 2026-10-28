# Helpers for /applications (ApplicationsController).
module ApplicationsHelper
  # Where clicking an app on /applications goes: its todos and steps, the
  # pipeline page (the app's tasks by lane). The pipeline is a 404 to an owner
  # for an AppCatalog::UNANNOUNCED app, so that owner lands on the app's page.
  def app_todos_path(app, admin:)
    return application_path(app.slug) if !admin && AppCatalog::UNANNOUNCED.include?(app.slug)

    pipeline_application_path(app.slug)
  end
end
