# frozen_string_literal: true

# A year of cache on fingerprinted /assets/*, a week on everything else under
# public/ (see lib/middleware/digested_asset_cache.rb for why the two differ).
#
# Outside ActionDispatch::Static, so it sees the headers Static wrote and replaces
# them for a digested path. Static is present in every environment (Rack::Deflater
# is anchored on it in config/application.rb).
#
# Required rather than autoloaded: `middleware` is on the autoload_lib ignore list in
# config/application.rb.
require Rails.root.join("lib/middleware/digested_asset_cache")

Rails.application.config.middleware.insert_before ActionDispatch::Static, DigestedAssetCache
