# Be sure to restart your server when you modify this file.

# Version of your assets, change this if you want to expire all your assets.
Rails.application.config.assets.version = "1.0"

# Add additional assets to the asset load path.
# Rails.application.config.assets.paths << Emoji.images_path

# Precompile additional assets.
# application.js, application.css, and all non-JS/CSS in the app/assets
# folder are already added.
# Rails.application.config.assets.precompile += %w[ admin.js admin.css ]

# Sprockets 4.2 knows no AVIF type, so it served the hero variants
# (app/assets/images/hero/*.avif) with no content-type at all. Registered here, an
# .avif asset goes out as image/avif from the dev server and the manifest alike.
Sprockets.register_mime_type "image/avif", extensions: [ ".avif" ]
