# Be sure to restart your server when you modify this file.

# Version of your assets, change this if you want to expire all your assets.
# Propshaft folds it into every digest.
Rails.application.config.assets.version = "1.0"

# Add additional assets to the asset load path.
# Rails.application.config.assets.paths << Emoji.images_path

# AVIF: the hero variants (app/assets/images/hero/*.avif). Propshaft takes an
# asset's content type from Rails' Mime registry, which knows no AVIF, so without
# this the dev and test server sent them with no type at all. Production serves
# the precompiled files through ActionDispatch::Static, which reads Rack::Mime; Rack
# 3 knows AVIF already, and the fallback below keeps it so on an older Rack.
Mime::Type.register "image/avif", :avif unless Mime::Type.lookup_by_extension(:avif)
Rack::Mime::MIME_TYPES[".avif"] ||= "image/avif"
