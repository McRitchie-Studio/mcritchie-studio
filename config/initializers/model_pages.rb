# frozen_string_literal: true

# Model-page protocol registry (studio-engine). Declares which models are
# reachable at the admin-only /models/:model/:id inspector. Registered inside
# `to_prepare` (not a bare initializer) so the engine's class-level registry is
# repopulated on every Zeitwerk code reload in development — re-registering
# points the "release" key at the freshly-reloaded Release constant.
#
# To expose another model, add a line here. For models with sensitive columns,
# register only after adding an `as_json` filter so the inspector's JSON doesn't
# leak them.
Rails.application.config.to_prepare do
  Studio::ModelPage.register("release", Release, lookup: :slug)
end
