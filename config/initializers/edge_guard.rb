# frozen_string_literal: true

# Arm EdgeGuard at the very front of the stack (see lib/middleware/edge_guard.rb for
# what it does and why the two halves are one class).
#
# Position 0 matters twice over. It has to run before Rack::Attack so the throttles
# measure the real visitor rather than a Cloudflare edge address — otherwise the
# login brute-force limits silently start protecting nothing. And refusing
# direct-to-origin traffic before host authorization, logging, and session loading
# keeps a flood of bypass attempts cheap: the whole point is that the 2026-08-09
# swarm could saturate this app with three concurrent requests.
#
# Required rather than autoloaded: `middleware` is on the autoload_lib ignore list in
# config/application.rb, so this is the single place the constant is defined.
require Rails.root.join("lib/middleware/edge_guard")

Rails.application.config.middleware.insert_before 0, EdgeGuard
