# frozen_string_literal: true

# DreamLayers — the layers a dream counts against, and each layer's budget, for
# the dream loop's swaps (docs/agents/modules/dream.md, Act 4).
#
# A layer key is one of:
#   "platform"               an approved dream with no soul (and no SOP step)
#   "soul/<slug>"            an approved dream tagged for that soul; a dream tagged
#                            for several souls counts in each of their layers
#   "step/<sop>/<step>"      an approved step dream (sop: and step: tags)
#
# Only APPROVED dreams fill a layer. A full layer means a swap, not an add. The
# caps are DreamBank::BUDGETS, the one source `bin/dream index --check` also reads.
require_relative "dream_bank"

module DreamLayers
  module_function

  PLATFORM = "platform"
  TOKEN = /\A[a-z0-9][a-z0-9+-]*\z/
  # The sessions a newly approved dream loads in before a swap may take it out
  # (app/models/dream_loop.rb counts them).
  GRACE_SESSIONS = 10

  def budgets = DreamBank::BUDGETS

  # Every layer key the dream counts in.
  def keys(dream)
    return [ "step/#{dream.sop}/#{dream.step}" ] if dream.step?
    return [ PLATFORM ] if dream.souls.empty?

    dream.souls.map { |soul| "soul/#{DreamBank.canonical_soul(soul)}" }.uniq
  end

  # The layer the dream lives in: its first.
  def key(dream) = keys(dream).first

  # "platform", "soul" or "step".
  def kind(key) = key.to_s.split("/").first

  def valid?(key)
    parts = key.to_s.split("/", -1)
    case parts.first
    when PLATFORM then parts.size == 1
    when "soul" then parts.size == 2 && TOKEN.match?(parts[1])
    when "step" then parts.size == 3 && parts.drop(1).all? { |part| TOKEN.match?(part) }
    else false
    end
  end

  def budget(key) = budgets.fetch(kind(key))

  # The approved dreams that fill the layer.
  def members(dreams, key)
    Array(dreams).select { |dream| dream.approved? && keys(dream).include?(key) }
  end

  # Every layer that holds an approved dream, platform first.
  def all(dreams)
    ([ PLATFORM ] + Array(dreams).select(&:approved?).flat_map { |dream| keys(dream) }).uniq
  end

  # "soul carl", "step building-sop · begin": how a person reads a key.
  def label(key)
    parts = key.to_s.split("/")
    case parts.first
    when "soul" then "soul #{parts[1]}"
    when "step" then "step #{parts[1]} · #{parts[2]}"
    else key.to_s
    end
  end
end
