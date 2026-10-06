# Managed-app registry seed: one App row per app and library in config/apps.yml
# (AppCatalog). Idempotent upsert, safe on every deploy.
#
# `color` is each app's status-line tint (#RRGGBB). bin/statusline quantizes it to
# the nearest xterm-256 color and tints the app slug, so a glance tells you which
# app a session is in. To change an app's name, glyph, color or status, edit
# config/apps.yml; this file only writes what the catalog says.
AppCatalog.seed_rows.each do |data|
  app = App.find_or_initialize_by(slug: data[:slug])
  app.assign_attributes(data.except(:slug))
  app.save! if app.new_record? || app.changed?
  puts "App: #{app.name} (#{app.slug}) — #{app.color}"
end
