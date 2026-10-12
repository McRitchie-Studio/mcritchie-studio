# frozen_string_literal: true

require "digest"
require "json"

# QaIdlPair — the turf-vault IDL allow-list bin/qa-server pins on a QA app's
# EXPECTED_IDL_HASH. Pure, IO-free and Rails-free: the caller hands in the
# target's config vars and a reader for repo files, so every verdict is provable
# in a unit test with no Heroku and no checkout.
#
# THE DEFECT IT CLOSES (/tasks/qa-server-idl-pair-heal). The registry declared
#
#     EXPECTED_IDL_HASH: sha256:config/turf_vault.idl.json
#
# a SINGLE hash of the v0.25 file. turf-monster-qa runs SOLANA_VAULT_GOVERNANCE=on,
# so it boots against config/turf_vault.v026.idl.json and its pin was the pair
# {v0.25, v0.26}. On rel-20261012-db4d68 the deploy's config heal saw that pair
# as "drift", PATCHed the lone v0.25 hash over it, and every boot after raised
# Solana::Config::IdlMismatchError (Heroku v280-v283 failed).
#
# THE RULE IS TURF'S, MIRRORED — NOT A NEW ONE. turf-monster's
# lib/solana/idl_selection.rb is the one implementation of "which IDL does this
# environment speak to", and turf's bin/deploy pins
#
#     <the file the target's switch selects>,<the file the OTHER switch selects>
#
# so a `heroku config:unset SOLANA_VAULT_GOVERNANCE` rollback (or the forward
# flip) still boots without a deploy. The pieces below are that file's
# governance?/network_from/idl_basename/sibling/declares_governance? applied to
# the hub's inputs, kept in the same order and with the same refusals:
#   * an EMPTY or unreadable switch refuses (it never silently means "off");
#   * an empty SOLANA_NETWORK refuses (a failed config read looks exactly like it);
#   * the selected file must exist and must declare `init_governance` iff the
#     switch is on (Solana::Config.verify_governance_alignment!, read ahead);
#   * the sibling joins the pair only when the checkout ships it.
# The hub cannot `require` turf's file: the deploy ref is not the turf primary's
# working tree, and hub CI has no turf checkout. If turf changes the rule, this
# mirror and its test change with it.
module QaIdlPair
  # `idl_pair:<stem>`, e.g. `idl_pair:config/turf_vault` — the stem turf's
  # idl_basename builds every file name from.
  SPEC = /\Aidl_pair:(.+)\z/

  GOVERNANCE_ENV_VAR = "SOLANA_VAULT_GOVERNANCE"
  GOVERNANCE_TRUE = %w[on 1 true yes enabled].freeze
  GOVERNANCE_FALSE = %w[off 0 false no disabled].freeze
  NETWORK_ENV_VAR = "SOLANA_NETWORK"
  MAINNET = "mainnet-beta"
  GOVERNANCE_INSTRUCTION = "init_governance"

  # Every refusal is one class: the caller (heal_registry_config) treats any of
  # them as "the declared side is unreadable" and skips the heal with a say-so,
  # which is the opposite of writing a guess over a working pin.
  class Refused < StandardError; end

  module_function

  def spec?(spec)
    SPEC.match?(spec.to_s)
  end

  def stem(spec)
    spec.to_s[SPEC, 1]
  end

  # Presence, then parse: an absent switch is the v0.25 shape, an empty one
  # refuses (turf's IdlSelection.governance?).
  def governance?(env)
    return false unless env.key?(GOVERNANCE_ENV_VAR)

    raw = env[GOVERNANCE_ENV_VAR].to_s.strip.downcase
    return true if GOVERNANCE_TRUE.include?(raw)
    return false if GOVERNANCE_FALSE.include?(raw)

    raise Refused, "#{GOVERNANCE_ENV_VAR} is #{raw.empty? ? "empty" : "unreadable"} on the target — " \
                   "refusing to choose an IDL (accepted: #{(GOVERNANCE_TRUE + GOVERNANCE_FALSE).join(" ")}, or unset)"
  end

  def network_from(env)
    raw = env[NETWORK_ENV_VAR].to_s.strip
    raise Refused, "#{NETWORK_ENV_VAR} is empty or unset on the target — refusing to choose an IDL" if raw.empty?

    raw
  end

  def idl_path(stem, network:, governance:)
    base = network == MAINNET ? "#{stem}.mainnet" : stem
    "#{base}#{governance ? ".v026" : ""}.idl.json"
  end

  def declares_governance?(content)
    JSON.parse(content.to_s).fetch("instructions", []).any? { |i| i["name"] == GOVERNANCE_INSTRUCTION }
  rescue JSON::ParserError
    false
  end

  # The allow-list value: "<selected>,<sibling>" (or the selected hash alone when
  # the checkout ships no sibling). `read` takes a repo-relative path and returns
  # its bytes, or nil when the file is not in the tree being deployed.
  def value(env, stem:, read:)
    network = network_from(env)
    governance = governance?(env)
    selected = idl_path(stem, network: network, governance: governance)
    content = read.call(selected)
    raise Refused, "#{selected} is missing from the deployed tree (#{network}, #{GOVERNANCE_ENV_VAR} " \
                   "#{governance ? "on" : "off"})" if content.nil?

    if declares_governance?(content) != governance
      raise Refused, "#{GOVERNANCE_ENV_VAR} is #{governance ? "on" : "off"} but #{selected} " \
                     "#{governance ? "lacks" : "declares"} #{GOVERNANCE_INSTRUCTION} — the app would refuse to boot"
    end

    sibling = read.call(idl_path(stem, network: network, governance: !governance))
    [content, sibling].compact.map { |bytes| Digest::SHA256.hexdigest(bytes) }.uniq.join(",")
  end

  # ── the comma allow-list as a SET ───────────────────────────────────────────
  # Solana::Config.expected_idl_hashes reads EXPECTED_IDL_HASH as a comma list,
  # so order and repeats carry no meaning; comparing the raw strings is what
  # called {v025,v026} "drift" from {v025}.

  def list(value)
    value.to_s.split(",").map(&:strip).reject(&:empty?).uniq
  end

  # The live pin already accepts every hash the deployed tree needs.
  def covers?(live, declared)
    (list(declared) - list(live)).empty?
  end

  def same_set?(left, right)
    list(left).sort == list(right).sort
  end

  # Pre-push WIDEN (turf bin/deploy's dance step 1): the live hashes plus the
  # incoming pair, so the slug still running keeps booting when the PATCH
  # restarts it.
  def widen(live, declared)
    (list(live) + list(declared)).uniq.join(",")
  end
end
