require "google/apis/errors"

module Workspace
  # The retry policy both clients share.
  #
  # Google answers a throttle with 429, and ALSO with 403 carrying a
  # rateLimitExceeded / userRateLimitExceeded reason — google-apis-core raises
  # Google::Apis::RateLimitError for those. A plain 403 (insufficient scope, or
  # a file we may not touch) arrives as Google::Apis::ClientError and must NOT
  # retry: retrying a permission refusal is just a slower refusal, and on this
  # codebase a 403 is frequently the guardrail working.
  module ApiRetry
    MAX_RETRIES = 5

    # Honour the server's own number when it sends one. Without this a long
    # Drive walk dies halfway through rather than waiting the second Google
    # asked for.
    def with_retries(label, sleeper: method(:sleep))
      attempts = 0
      begin
        attempts += 1
        yield
      rescue ::Google::Apis::RateLimitError, ::Google::Apis::ServerError,
             ::Google::Apis::TransmissionError => e
        raise Error, "Google #{label} failed after #{attempts} attempt(s): #{e.class}: #{e.message}" if attempts > MAX_RETRIES

        sleeper.call(retry_after(e) || 2**(attempts - 1))
        retry
      end
    end

    # Google::Apis::Error carries the response header hash. Header casing is not
    # guaranteed across transports, so both spellings are read rather than
    # assuming one.
    def retry_after(error)
      headers = error.respond_to?(:header) ? error.header : nil
      return nil if headers.nil?

      value = headers["Retry-After"] || headers["retry-after"]
      seconds = value.to_i
      seconds.positive? ? seconds : nil
    end

    # One wrapped type for callers to rescue, mirroring Gmail::Client::Error.
    Error = Class.new(StandardError)
  end
end
