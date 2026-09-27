module ImageGeneration
  # WHAT ANY GENERATOR ANSWERS WITH, whichever vendor ran.
  #
  # Adapters return one of these rather than their own payload shape, so the
  # persistence, the provenance stamp and the page are written against ONE thing
  # and a new generator cannot change what they read. Same contract as
  # Appearances::ImageSearch::Answer one lane over, for the same reason.
  #
  # `seed` AND `version` ARE NOT DECORATION. They are the two halves of the
  # operator's "deterministic": the version says WHICH model ran, the seed says
  # which draw. Together they are what makes a sheet from March comparable to one
  # from January, and what tells a regression apart from a provider change.
  #
  # `billable_units` IS THE MEASURED QUANTITY, `cost_usd` THE DERIVED PRICE, and
  # they are separate members on purpose. The unit count is what the vendor
  # actually reported; the price is that count times a rate this repo declares in
  # config/image_generators.yml. Keeping both means a rate correction re-prices
  # the back-catalogue arithmetically instead of stranding dollar figures nobody
  # can re-derive.
  #
  # BOTH ARE OPTIONAL AND OFTEN NIL, which is the honest state. Not every vendor
  # reports what a call cost on the call itself; a nil here means "not reported",
  # never "free", and the page must render it as the former.
  Result = Struct.new(:image_urls, :seed, :request_id, :generator_key, :version,
                      :cost_usd, :billable_units, :raw, keyword_init: true) do
    def image_urls = (self[:image_urls] || [])
    def any? = image_urls.any?
    def primary_url = image_urls.first
  end
end
