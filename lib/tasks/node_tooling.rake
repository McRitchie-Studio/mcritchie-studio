# frozen_string_literal: true

# studio-engine's Node tooling package, linked into this checkout
# (lib/node_tooling_link.rb says why this wraps the engine's own task).
#
#   bin/rails node_tooling:link    # node_modules/.studio-engine -> the bundled gem's package
#   bin/rails studio:node:check    # the engine's drift check against versions.json
#
# bin/test-js, bin/prod-smoke, bin/e2e-census-check and CI's playwright lane run the
# link for you. Run it yourself after an `npm ci`, which deletes node_modules.
# Neither task loads :environment.
require_relative "../node_tooling_link"

namespace :node_tooling do
  desc "Link studio-engine's Node tooling at node_modules/.studio-engine, refusing a shared node_modules or Heroku"
  task :link do
    status, message = NodeToolingLink.call(root: Rails.root, tooling: Studio::NodeTooling)
    abort("node_tooling:link: #{message}") if status == :refused
    puts "node_tooling:link: #{message}"
  end
end
