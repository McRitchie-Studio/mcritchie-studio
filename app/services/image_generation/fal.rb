require "net/http"
require "json"

module ImageGeneration
  # THE fal.ai ADAPTER — one class, many rows.
  #
  # It is constructed AROUND a registry row rather than around a model name, so
  # `fal_ideogram_character` and `fal_flux_pulid` share every line below and
  # differ only in what config/image_generators.yml says about them. That split is
  # the registry earning its keep: a third fal model is a row, not a subclass.
  #
  # ⚠ POST IS NOT A READ. `POST https://queue.fal.run/<model>` SUBMITS BILLABLE
  # WORK. Measured 2026-09-26: an auth probe with an EMPTY body answered HTTP 200
  # because it queued a job. Probe this API with the GET status endpoint — a real
  # key answers 404 for an unknown request id, a bogus key answers 401, and
  # neither spends. Nothing in this class may POST on a path that is not an
  # explicit, admin-gated generation.
  #
  # THE QUEUE IS THREE CALLS, all under one host:
  #   POST /<endpoint>                    -> { request_id, status_url, response_url, ... }
  #   GET  <status_url>                   -> { status: IN_QUEUE|IN_PROGRESS|COMPLETED }
  #   GET  <response_url>                 -> { images: [{ url }], seed }
  # Shapes read off the published OpenAPI document for the endpoint on
  # 2026-09-26, which is what the row's `api_version` pins.
  #
  # ⚠ THE POLL URLS COME FROM THE SUBMIT RESPONSE, NEVER FROM THE ENDPOINT.
  # This is measured, and getting it wrong costs a paid image rather than a retry.
  # The OpenAPI document for `fal-ai/ideogram/character` DOCUMENTS its status path
  # as `/fal-ai/ideogram/character/requests/{id}/status` — and that path answers
  # HTTP 405 on the live host (measured 2026-09-26 against a real submitted job).
  # The queue routes under the first TWO segments only, `fal-ai/ideogram`, because
  # `character` is a sub-path of the app rather than an app of its own.
  #
  # So the published contract and the live host DISAGREE, and the submit response
  # is the only source that is right for both: it returns `status_url`,
  # `response_url` and `cancel_url` fully formed. Constructing them from the
  # endpoint is what stranded a job we had already paid for — the work completes
  # on the vendor's side either way, so a poll that 405s burns the money and
  # returns nothing.
  #
  # `queue_base` below is a FALLBACK for a response that omits them, and it
  # implements the two-segment rule rather than the documented one.
  class Fal
    BASE_URL = "https://queue.fal.run".freeze

    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 60

    # Poll budget for #generate_and_wait. Generous: an image model behind a queue
    # routinely takes 20-40s, and a timeout here costs the call we already paid
    # for — the work completes on the vendor's side either way.
    POLL_INTERVAL = 2
    POLL_TIMEOUT = 180

    COMPLETED = "COMPLETED".freeze
    PENDING_STATUSES = %w[IN_QUEUE IN_PROGRESS].freeze

    # Set to "1" to make every call through here raise instead of reaching the
    # network. Armed suite-wide in test/test_helper.rb, following
    # Athletes::VisionTransport and the fake `op` already on PATH.
    NO_LIVE_CALLS_ENV = "FAL_NO_LIVE_CALLS".freeze

    class Error < StandardError; end
    class NotConfigured < Error; end
    # DESCENDS FROM THE SHARED ANCESTOR so a caller can rescue one type across
    # every adapter — see ImageGeneration::GenerationFailed for why that matters.
    class GenerationError < ImageGeneration::GenerationFailed; end
    class TimeoutError < Error; end

    # DELIBERATELY OUTSIDE StandardError, and this is the load-bearing detail.
    #
    # Every caller of this adapter degrades rather than raises — a dead generator
    # must cost the operator an image, never the page — so they rescue
    # StandardError. A trap that raised a StandardError would therefore be
    # SWALLOWED by the very code it guards: the careless test would see an empty
    # result, pass quietly, and the trap would have proven nothing while the bill
    # arrived anyway. Sitting outside StandardError means the degrade cannot catch
    # it. Same reasoning, same shape as Athletes::VisionTransport::LiveCallAttempted.
    class LiveCallAttempted < Exception; end # rubocop:disable Lint/InheritException

    # A SUBMITTED JOB, and the URLs the vendor said to poll it with. Carrying the
    # vendor's own URLs rather than an id alone is what keeps the caller off the
    # documented-but-wrong path above.
    Ticket = Struct.new(:request_id, :status_url, :response_url, keyword_init: true)

    def self.armed? = ENV[NO_LIVE_CALLS_ENV].to_s == "1"

    attr_reader :row

    # WHAT THE VENDOR SAID ABOUT THE LAST CALL, beyond its body.
    #
    # fal answers with `x-fal-*` headers, and any billing figure it volunteers
    # arrives there rather than in the JSON. Kept so a cost can be MEASURED off
    # the call that incurred it instead of copied from a price page that moves.
    #
    # THIS IS NOT A GUARANTEED SOURCE and the code must not pretend otherwise:
    # our key lacks the `billing:usage:read` scope (measured 2026-09-26 — the
    # billing endpoint answers HTTP 403), so if the header is absent the cost is
    # NOT REPORTED and stays nil. nil never means free.
    attr_reader :last_headers

    # `api_key` IS INJECTABLE but defaults to the row's declared variable. The
    # row names the variable; this class never spells one.
    def initialize(row, api_key: nil, clock: Time)
      @row = row
      @api_key = api_key || ENV[row.credential_env.to_s]
      @clock = clock
      raise NotConfigured, row.unconfigured_message if @api_key.blank?
    end

    # SUBMIT ONE GENERATION AND WAIT FOR IT. Returns an ImageGeneration::Result.
    #
    # `seed:` IS PASSED THROUGH WHEN GIVEN and echoed back by the vendor when not,
    # which is why the Result carries whatever came back rather than whatever went
    # in. Recording the seed we SENT would record nil for every call that did not
    # pin one, losing the only handle that could reproduce it.
    # THE BILLING HEADER IS ON THE SUBMIT RESPONSE, not on the polls, so it is
    # captured HERE and carried into the Result the polls build. Reading it off
    # the last call instead would record whatever the final GET reported, which
    # is nothing.
    def generate_and_wait(prompt:, reference_urls:, seed: nil, image_size: nil, num_images: 1)
      ticket = submit(prompt: prompt, reference_urls: reference_urls,
                      seed: seed, image_size: image_size, num_images: num_images)
      units = billable_units
      await(ticket)
      result(ticket).tap do |r|
        r.billable_units = units
        r.cost_usd = row.price_for(units)
      end
    end

    # WHAT THE VENDOR SAID IT BILLED for the most recent call, or nil.
    #
    # MEASURED, NOT ESTIMATED — this is the whole reason #last_headers exists.
    # Measured 2026-09-26: one image at the API-default rendering speed reported
    # `x-fal-billable-units: 3`.
    def billable_units
      raw = last_headers.to_h["x-fal-billable-units"]
      return nil if raw.blank?

      Integer(raw, exception: false)
    end

    # ⚠ THIS IS THE LINE THAT SPENDS MONEY. Admin-gated at every call site.
    def submit(prompt:, reference_urls:, seed: nil, image_size: nil, num_images: 1)
      urls = Array(reference_urls).compact_blank
      raise GenerationError, "#{row.label} needs at least one reference image" if urls.empty?

      body = { prompt: prompt, num_images: num_images }
      body[:seed] = seed if seed
      body[:image_size] = image_size if image_size.present?
      body[reference_field_key] = reference_payload(urls)

      payload = perform(:post, "/#{row.endpoint}", body: body)
      id = payload["request_id"].presence
      raise GenerationError, "#{row.label} returned no request_id" if id.blank?

      Ticket.new(
        request_id: id,
        status_url: payload["status_url"].presence || "#{BASE_URL}#{status_path(id)}",
        response_url: payload["response_url"].presence || "#{BASE_URL}#{result_path(id)}"
      )
    end

    # FREE — a read. Returns the vendor's status string. Takes the Ticket from
    # #submit, or a bare request id for a job whose ticket was not kept.
    def status(ticket)
      perform(:get, ticket_for(ticket).status_url)["status"].to_s
    end

    # FREE — a read of work already paid for.
    def result(ticket)
      ticket = ticket_for(ticket)
      payload = perform(:get, ticket.response_url)
      Result.new(
        image_urls: Array(payload["images"]).filter_map { |i| i.is_a?(Hash) ? i["url"].presence : nil },
        seed: payload["seed"],
        request_id: ticket.request_id,
        generator_key: row.key,
        version: row.provenance_version,
        cost_usd: nil,
        raw: payload
      )
    end

    private

    attr_reader :api_key, :clock

    # THE ROW DECIDES THE FIELD NAME AND WHETHER IT IS A LIST. fal's own models
    # disagree with each other — ideogram/character takes `reference_image_urls`
    # (array), flux-pulid takes `reference_image_url` (string) — and that
    # disagreement is exactly the kind of per-model fact the registry exists to
    # hold instead of a conditional in here.
    def reference_field_key = (row.reference_field.presence || "reference_image_urls").to_sym

    def reference_payload(urls)
      row.reference_arity.to_s == "one" ? urls.first : urls
    end

    # A BARE ID IS STILL ACCEPTED, so a job whose ticket was lost — a console, a
    # retry in another process — can still be collected. It reconstructs from the
    # TWO-SEGMENT rule, which is the one the live host implements.
    def ticket_for(ticket)
      return ticket if ticket.is_a?(Ticket)

      id = ticket.to_s
      Ticket.new(request_id: id,
                 status_url: "#{BASE_URL}#{status_path(id)}",
                 response_url: "#{BASE_URL}#{result_path(id)}")
    end

    # THE FIRST TWO SEGMENTS, not the whole endpoint. `fal-ai/ideogram/character`
    # queues under `fal-ai/ideogram`; the documented per-sub-path form answers 405.
    def queue_base = row.endpoint.to_s.split("/").first(2).join("/")
    def status_path(id) = "/#{queue_base}/requests/#{id}/status"
    def result_path(id) = "/#{queue_base}/requests/#{id}"

    def await(ticket)
      deadline = clock.now + POLL_TIMEOUT
      loop do
        state = status(ticket)
        return state if state == COMPLETED
        unless PENDING_STATUSES.include?(state)
          raise GenerationError, "#{row.label} answered status #{state.inspect}"
        end
        if clock.now >= deadline
          raise TimeoutError,
                "#{row.label} did not finish request #{ticket_for(ticket).request_id} " \
                "within #{POLL_TIMEOUT}s"
        end

        sleep(POLL_INTERVAL)
      end
    end

    # THE ONE PLACE A SOCKET OPENS, which is why the trap lives here and not on
    # the public methods: a future method that forgets to check is still caught.
    def perform(verb, path, body: nil)
      if self.class.armed?
        raise LiveCallAttempted, <<~WHY
          A live fal.ai call was attempted with #{NO_LIVE_CALLS_ENV}=1 armed.
          Every paid call to this vendor goes through ImageGeneration::Fal#perform, and
          the suite arms this so no test can spend. Drive the recorded seam instead:

            client = ImageGeneration::Fal.new(row, api_key: "test")
            client.define_singleton_method(:perform) { |_verb, _path, body: nil| { ... } }

          If you are NOT in a test, something set #{NO_LIVE_CALLS_ENV}=1 in your
          environment. Verb was #{verb.to_s.upcase} #{path}.
        WHY
      end

      # `path` is a bare path on the POST and a FULLY-FORMED vendor URL on the
      # polls, because the submit response hands those back absolute.
      uri = path.to_s.start_with?("http") ? URI.parse(path) : URI.join(BASE_URL, path)
      request = build_request(verb, uri, body)
      response = http(uri).request(request)
      interpret(response, verb, path)
    end

    def build_request(verb, uri, body)
      klass = verb.to_sym == :post ? Net::HTTP::Post : Net::HTTP::Get
      request = klass.new(uri)
      # fal's documented scheme, and the same shape Higgsfield::Client uses one
      # service over: a single Authorization header carrying `key_id:key_secret`.
      request["Authorization"] = "Key #{api_key}"
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(body) if body
      request
    end

    def http(uri)
      Net::HTTP.new(uri.host, uri.port).tap do |h|
        h.use_ssl = true
        h.open_timeout = OPEN_TIMEOUT
        h.read_timeout = READ_TIMEOUT
      end
    end

    # A NON-2XX RAISES, and it raises with the vendor's own words in it. An HTTP
    # 401 that returned an empty Result would be indistinguishable from a model
    # that generated nothing, and those two send an operator to completely
    # different places.
    def interpret(response, verb, path)
      @last_headers = response.each_header.to_h.select { |k, _| k.to_s.start_with?("x-fal-") }
      parsed = begin
        JSON.parse(response.body.to_s)
      rescue JSON::ParserError
        {}
      end
      return parsed if response.is_a?(Net::HTTPSuccess)

      detail = parsed["detail"] || parsed["error"] || response.body.to_s.truncate(200)
      raise GenerationError,
            "#{row.label} answered HTTP #{response.code} to #{verb.to_s.upcase} #{path}: #{detail}"
    end
  end
end
