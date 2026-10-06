# WHICH PROXY HEADER NAMES THE CLIENT. One answer for every reader of the
# client address: Rack::Attack's `req.ip` and Rails' `request.remote_ip`.
#
# Rack 3 reads the standard `Forwarded` header BEFORE `X-Forwarded-For`
# (Rack::Request.forwarded_priority defaults to [:forwarded, :x_forwarded]),
# and Rails' RemoteIp middleware takes its list from the same method
# (ActionDispatch::Request#forwarded_for is Rack's). Neither the Heroku router
# nor EdgeGuard (lib/middleware/edge_guard.rb) sets or strips `Forwarded`, so
# without this line a caller writes their own address:
#
#     Forwarded: for=203.0.113.9
#
# and every per-IP throttle in config/initializers/rack_attack.rb (login/ip,
# signup/ip, sso_continue/ip, oauth_callback/ip, chat/ip) counts them as that
# address, a fresh one on each request if they like, or someone else's.
#
# The header the platform controls is X-Forwarded-For. The Heroku router
# appends the address it received the request from to the right of any list
# the client sent (https://devcenter.heroku.com/articles/http-routing). An armed
# EdgeGuard sets both REMOTE_ADDR and that list to Cloudflare's
# CF-Connecting-IP, and a public REMOTE_ADDR already outranks `Forwarded`, so
# the gap this line closes is every request EdgeGuard does not rewrite. Rack
# and Rails both walk the list from the right and stop at the first address
# that is not a private one, so a value the client put on the left is never
# reached. With `Forwarded` out of the list, every reader gets the address the
# platform wrote.
#
# It also keeps `Forwarded: proto=...` from setting request.scheme (and so
# `request.ssl?`), which Rails takes from Rack through the same priority list,
# and `Forwarded: host=...` from reaching Rack::Request#host and #authority for
# any middleware that builds a plain Rack::Request. Rails' own request.host
# reads X-Forwarded-Host or Host and never `Forwarded`. X-Forwarded-Proto and
# X-Forwarded-Port, which the router sets, are unaffected.
#
# A request with no `Forwarded` header, which is every browser request the
# router forwards, is read exactly as it would be without this line.
#
# If a proxy that speaks `Forwarded` is ever put in front of the router,
# revisit this. test/integration/client_ip_spoof_test.rb holds the property.
Rack::Request.forwarded_priority = [:x_forwarded]
