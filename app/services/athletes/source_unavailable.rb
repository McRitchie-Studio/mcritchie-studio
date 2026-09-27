module Athletes
  # A SOURCE COULD NOT BE REACHED, as opposed to a source that answered and had
  # nothing. Part of the provider SEAM's contract rather than any one provider's
  # vocabulary: Athletes::AcquireOrValidate rescues this, so a second source can be
  # written without the act learning its name, and every provider raises a subclass
  # of it (Espn::PlayerProfile::SourceUnavailable).
  #
  # The distinction is the whole point. "ESPN has no athlete 4890973" is a fact
  # about our record and the operator should go and fix it; "ESPN answered 503" is a
  # fact about the afternoon and the operator should re-run. Collapsing them into a
  # shared nil is how a nothing-happened run reads as a verdict about the data.
  class SourceUnavailable < StandardError; end
end
