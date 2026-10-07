# frozen_string_literal: true

# The hub, booted in PRODUCTION, answers one question for
# test/integration/component_gallery_production_test.rb: who reaches the
# component gallery? Rails.env is fixed per process, so the test runs this file
# in its own process:
#
#   RAILS_ENV=production bin/rails runner test/support/component_gallery_probe.rb
#
# It boots the real app (eager load, force_ssl, host authorization, the real
# config/initializers/studio.rb), so the flag it reads is the one production
# reads. It asks twice:
#
#   1. as booted (the hub sets Studio.lookbook_in_production = true);
#   2. the control: the flag turned off and the routes redrawn, which is what
#      production draws if the initializer line is deleted.
#
# Each pass records what is drawn and what a visitor, a signed-in non-admin and
# a signed-in admin get from every gallery path. The users it signs in are
# created inside a transaction it rolls back, so the database it is pointed at
# (the caller's test database) is left as it was.
#
# The result is JSON, written to PROBE_RESULT.

require "json"

module ComponentGalleryProbe
  GALLERY = Studio::ComponentGallery::MOUNT_PATH
  PREVIEWS = Studio::ComponentGallery::PREVIEWS_ROUTE
  ASSETS = Studio::ComponentGallery::ASSETS_PATH

  # Every path a visitor might try: the gallery, a preview's inspector page and
  # its rendered frame, ViewComponent's own preview pages, and Lookbook's UI
  # assets. The badge is the preview studio-engine ships.
  PATHS = {
    "gallery" => GALLERY,
    "inspect" => "#{GALLERY}/inspect/studio/badge/tones",
    "preview_frame" => "#{GALLERY}/preview/studio/badge/tones",
    "previews_index" => PREVIEWS,
    "previews_badge" => "#{PREVIEWS}/studio/badge_component/tones",
    "assets_css" => "#{ASSETS}/css/lookbook.css",
    "assets_js" => "#{ASSETS}/js/lookbook.js"
  }.freeze

  module_function

  def host
    Rails.application.config.hosts.find { |entry| entry.is_a?(String) } || "mcritchie.studio"
  end

  def session
    ActionDispatch::Integration::Session.new(Rails.application).tap do |s|
      s.host! host
      s.https!
    end
  end

  # Signs a user in the way a browser does on the live hub: open the magic
  # link's confirm page, then submit its form. Production checks the CSRF
  # token (test does not), so the POST carries the one the page rendered.
  def signed_in(user)
    s = session
    token = Studio::Link.create_magic_link(email: user.email).token
    s.get "/l/#{token}"
    csrf = Nokogiri::HTML(s.response.body).at_css("input[name='authenticity_token']")&.[]("value")
    raise "the confirm page for #{user.email} has no CSRF token (#{s.response.status})" if csrf.blank?

    s.post "/l/#{token}", params: { authenticity_token: csrf }
    unless s.response.redirect? && s.controller.session[Studio.session_key.to_s].present?
      raise "sign-in for #{user.email} failed: #{s.response.status} #{s.controller.session.to_hash.except('_csrf_token')}"
    end

    s
  end

  # The status every path answers, and whether a 404 named Lookbook.
  def statuses(s)
    PATHS.transform_values do |path|
      s.get path
      { "status" => s.response.status, "names_lookbook" => s.response.body.to_s.include?("lookbook") }
    end
  end

  def drawn
    paths = Rails.application.routes.routes.map { |route| route.path.spec.to_s }
    {
      "mounted" => Studio.lookbook_mounted?,
      "gallery_routes" => paths.select { |path| path.start_with?(GALLERY) },
      "asset_routes" => paths.select { |path| path.start_with?(ASSETS) },
      "preview_routes" => paths.select { |path| path.start_with?(PREVIEWS) || path.include?("view_components") },
      "rack_static" => Rails.application.middleware.any? { |middleware| middleware.klass == Rack::Static }
    }
  end

  def pass(admin, member)
    admin_session = signed_in(admin)
    admin_session.get GALLERY
    gallery_body = admin_session.response.body.to_s
    admin_session.get PATHS.fetch("preview_frame")
    frame_body = admin_session.response.body.to_s

    drawn.merge(
      "visitor" => statuses(session),
      "member" => statuses(signed_in(member)),
      "admin" => statuses(signed_in(admin)),
      "admin_gallery_lists_badge" => gallery_body.include?("studio/badge"),
      "admin_frame_renders_badge" => frame_body.include?(%(<span class="badge ))
    )
  end

  def run
    # Production serves the stylesheets the slug precompiled (assets.compile is
    # off); this boot precompiled none, so a preview frame's stylesheet_link_tag
    # would raise AssetNotFound. Let the tag fall back to a plain path instead:
    # what is under test is who reaches the frame and that it renders, not the
    # asset build.
    ActionView::Base.unknown_asset_fallback = true

    result ={ "env" => Rails.env, "flag" => Studio.lookbook_in_production, "eager_load" => Rails.application.config.eager_load }

    ActiveRecord::Base.transaction do
      stamp = SecureRandom.hex(4)
      admin = User.create!(name: "Gallery Probe Admin", email: "gallery-admin-#{stamp}@probe.test", role: "admin")
      member = User.create!(name: "Gallery Probe Member", email: "gallery-member-#{stamp}@probe.test", role: "viewer")

      result["on"] = pass(admin, member)

      # The control: production as it is without the initializer line.
      Studio.lookbook_in_production = false
      Rails.application.reload_routes!
      result["off"] = pass(admin, member)

      raise ActiveRecord::Rollback
    end

    result
  end
end

File.write(ENV.fetch("PROBE_RESULT"), JSON.generate(ComponentGalleryProbe.run))
