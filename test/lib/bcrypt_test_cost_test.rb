# frozen_string_literal: true

require "test_helper"

# [unit] The test environment hashes passwords at bcrypt's MINIMUM cost.
#
# bcrypt is slow by design. At the library default (cost 12) one hash costs ~272ms
# here, and test/fixtures/users.yml mints two through ERB on every fixture LOAD —
# once per process, once per parallel CI worker, and again for every
# non-transactional test (`invalidate_already_loaded_fixtures`; 16 such cases).
# Measured: ~9s a local run, ~11s across CI's four workers, spent hashing passwords
# no assertion ever reads.
#
# WHICH CALL PATH ACTUALLY NEEDED FIXING — the surprise, and why this file is short.
# Rails ALREADY handles `has_secure_password`: `ActiveModel::Railtie` runs
# `ActiveModel::SecurePassword.min_cost = Rails.env.test?`, so that path has always
# hashed at MIN_COST here. But `min_cost` is read ONLY by `has_secure_password`. The
# fixture does not go through it — a bare `BCrypt::Password.create(...)` reads
# `BCrypt::Engine.cost` and is completely unaffected. Measured directly: with
# `min_cost = true`, a bare create still returns a cost-12 hash. So the engine
# setting in config/environments/test.rb covers the one path Rails' knob cannot
# reach, and covers any future direct call site for free.
#
# There is deliberately NO test here for the `has_secure_password` path. One was
# written and REMOVED: it passed with the fix disabled, because Rails was already
# satisfying it. A test that cannot fail reports coverage it does not have — the
# disease config/test_health.yml exists to ratchet.
#
# THESE ASSERT THE EFFECT, NOT THE SETTING. Reading back the config value we just
# wrote would pass whether or not bcrypt honoured it. Each test HASHES SOMETHING and
# reads the cost off the resulting digest. Both FAIL (12 != 4) with the engine line
# commented out — verified, not assumed.
class BcryptTestCostTest < ActiveSupport::TestCase
  test "a directly minted digest carries the minimum cost" do
    # The fixture's call shape: a bare create, reading BCrypt::Engine.cost.
    assert_equal BCrypt::Engine::MIN_COST, BCrypt::Password.create("whatever").cost
  end

  test "the fixtures on disk are not themselves pinned to a high cost" do
    # This is the one that proves the saving LANDS. A digest baked as a literal into
    # the fixture file would survive the env setting entirely; the fixture mints via
    # ERB at load time, so a cheap digest here means the load itself got cheaper.
    assert_equal BCrypt::Engine::MIN_COST, BCrypt::Password.new(users(:alex).password_digest).cost
  end
end
