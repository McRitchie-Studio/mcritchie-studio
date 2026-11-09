# frozen_string_literal: true

require_relative "op_meter"

# AuthRefresh — one refresh after a service refuses a credential, and no more.
#
#   AuthRefresh.run(item: "heroku.studio.agents", service: "heroku",
#                   read: -> { cached_value }, refresh: -> { fresh_value_from_1password },
#                   rejected: ->(result) { result.status == 401 }) do |value|
#     call_the_service(value)
#   end
#
# WHY (task secret-refresh-on-auth-failure, 2026-11-09). The secret cache and the
# soul secret sets serve a credential from disk for hours. When the credential is
# ROTATED in 1Password, the cached copy is dead but still served, and the service
# answers 401 until the entry expires. The cause has a name: the copy is stale.
# So the caller forgets the copy, reads the item fresh from 1Password ONCE, and
# tries the call ONCE more.
#
# THIS IS A NAMED-CAUSE REFRESH, NOT A BLIND RETRY. Only a refusal of the
# credential starts it (the caller's `rejected` test, or the block raising
# Rejected). Any other failure (a 404, a 500, a timeout, a merge conflict) is
# returned untouched, because a fresh credential does not change it. A second
# refusal after the fresh read means the 1Password item itself is bad (revoked,
# wrong field, wrong account): the run STOPS and raises StillRefused, which names
# the item and the service. There is no loop and no back-off: at most one fresh
# read and two calls.
#
# EVERY REFRESH IS LOGGED, in the 1Password read log (bin/op-reads --by action):
# action `auth-refresh`, via `<service>:<item>`, outcome `ok`, `still-refused` or
# `refresh-failed`. It is also said on stderr. NEVER A VALUE: the lines carry the
# item and the service names only. The value is handed to the block and nowhere
# else; this file never prints, logs or stores it.
#
# BOUNDED. This file runs no `op` itself. `refresh` is the caller's own bounded
# read (SoulSecrets.fetch and bin/gh-token both go through OpMeter, at most 20 s an
# attempt).
#
# Ruby 2.6 syntax, like soul_secrets.rb (bin/gh-token loads it under system Ruby).
module AuthRefresh
  ACTION = "auth-refresh"
  NAME = /\A[A-Za-z0-9][A-Za-z0-9._:-]{0,79}\z/.freeze
  # Token- and key-shaped text (bin/gh-token's SECRET_SHAPED): never a name.
  SECRET_SHAPED = %r{ops_|gh[a-z]_|github_pat_|[A-Za-z0-9+/=_-]{32,}}.freeze

  # The block raises this when the service refused the credential, for a caller
  # that has no result to classify (an exception-shaped client).
  class Rejected < StandardError; end

  # The base of the two stops. #item and #service name what to check; #result is
  # the last refused answer (nil when the block raised Rejected), so a caller can
  # still show what the service said.
  class Stop < StandardError
    attr_reader :item, :service, :result

    def initialize(message, item:, service:, result: nil)
      super(message)
      @item = item
      @service = service
      @result = result
    end
  end

  # The service refused the fresh value too: the 1Password item itself is bad.
  class StillRefused < Stop; end

  # The fresh read from 1Password failed (hung, signed out, rate-limited).
  class RefreshFailed < Stop; end

  module_function

  # Call the block with the current value. When the service refuses it, forget
  # the cached copy, read the item fresh once (+refresh+), and call the block
  # once more. Returns the block's result. Raises StillRefused or RefreshFailed.
  #
  #   item      the 1Password item name (logged; never a value)
  #   service   the service that refused it, e.g. "github" (logged)
  #   read      -> the value to try first; nil is allowed (an ambient login)
  #   refresh   -> forgets the cached copy and returns a value read fresh from
  #                1Password; raises on failure (its message must hold no value)
  #   rejected  -> result -> true when +result+ is the service refusing the
  #                credential. Omit it when the block raises Rejected instead.
  #   say       -> line -> where the stderr narration goes (default $stderr)
  #   how       the words for the refresh step, for the narration
  def run(item:, service:, refresh:, read: -> {}, rejected: nil, env: ENV, say: nil,
          how: "forgetting the cached copy and reading it fresh from 1Password once")
    item = label(item)
    service = label(service)
    say ||= ->(line) { $stderr.puts(line) }

    result, refused = attempt(read.call, rejected) { |value| yield value }
    return result unless refused

    say.call("auth-refresh: #{service} refused #{item} (a rotated or revoked credential); #{how}, then trying once more")
    fresh = begin
      refresh.call
    rescue StandardError => e
      record(item, service, "refresh-failed", env)
      raise RefreshFailed.new("auth-refresh: #{service} refused #{item}, and the fresh read from 1Password failed " \
                              "(#{e.message}); stopping", item: item, service: service, result: result)
    end

    result, refused = attempt(fresh, rejected) { |value| yield value }
    if refused
      record(item, service, "still-refused", env)
      raise StillRefused.new("auth-refresh: #{service} still refuses #{item} after one fresh read from 1Password; " \
                             "stopping. Check the item in 1Password (rotated, revoked, or the wrong field or account).",
                             item: item, service: service, result: result)
    end
    record(item, service, "ok", env)
    say.call("auth-refresh: #{service} accepted the fresh #{item}")
    result
  end

  # [result, refused?]. A Rejected raise is a refusal with no result.
  def attempt(value, rejected)
    result = yield value
    [result, rejected ? (rejected.call(result) ? true : false) : false]
  rescue Rejected
    [nil, true]
  end

  # One row in the read log. Names only; a name that does not look like one is
  # replaced, so a caller that passes a value by mistake cannot log it.
  def record(item, service, outcome, env = ENV)
    OpMeter.record(action: ACTION, outcome: outcome, via: "#{label(service)}:#{label(item)}", env: env)
  end

  def label(name)
    text = name.to_s.strip
    NAME.match?(text) && !SECRET_SHAPED.match?(text) ? text : "unnamed"
  end
end
