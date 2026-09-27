module ImageGeneration
  # THE ONE ERROR A CALLER RESCUES, whichever vendor ran.
  #
  # Each adapter keeps its own `GenerationError` so its message can name itself,
  # and both descend from this. Without a shared ancestor every caller would have
  # to enumerate the adapters — `rescue ImageGeneration::Fal::GenerationError,
  # ImageGeneration::OpenAI::GenerationError` — which is a list that silently goes
  # stale the day a row gains a third adapter, and goes stale in the direction
  # that lets an exception escape as a 500.
  #
  # That is the same failure the registry exists to prevent one layer up: a caller
  # should name what it needs, never who provides it.
  class GenerationFailed < StandardError; end
end
