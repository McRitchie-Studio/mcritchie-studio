module Workspace
  # What an exception is allowed to leave behind — in a durable column, or in a
  # terminal an operator will paste somewhere.
  #
  # The rule the reviewers asked for: report the CLASS plus a bounded FAULT
  # TOKEN, never `e.message`. A raw message is vendor-controlled text of
  # unbounded length; here it routinely echoes the subject address and the
  # titles of files we deliberately do not copy, and on the credential path a
  # message once carried a whole private key (Credentials#parse documents it).
  #
  # But a token is not noise — `backendError`, `unauthorized_client`,
  # `notFound` ARE the diagnosis, and throwing them away to be safe makes a
  # recorded failure useless. So one short token survives, and only if it is
  # shaped like a slug.
  module ErrorSlug
    MAX = 120

    # A real fault token is one short identifier. The cap and the character
    # class together are the guard: a PEM header is rejected (it leads with
    # "-"), an address is rejected (no "@" in the class), and a base64 run is
    # cut off by the length bound long before it is a useful fragment.
    TOKEN = /\A[A-Za-z][A-Za-z0-9_]{0,31}\z/

    def self.for(error)
      return "unknown error" if error.nil?

      token = fault_token(error)
      return clamp("#{error.class}: #{token}") if token

      status = error.respond_to?(:status_code) ? error.status_code : nil
      return clamp("#{error.class}: HTTP #{status}") if status

      clamp(error.class.to_s)
    end

    # Google states the fault two ways: as JSON (`"error": "unauthorized_client"`)
    # and as prose that LEADS with the token ("backendError on <folder>"). Both
    # are read; neither is trusted — each candidate must still match TOKEN.
    def self.fault_token(error)
      body = error.message.to_s
      candidate = body[/"error"\s*:\s*"([^"]+)"/, 1] ||
                  body[/"reason"\s*:\s*"([^"]+)"/, 1] ||
                  body[/\A\s*([A-Za-z][A-Za-z0-9_]*)/, 1]

      candidate&.[](TOKEN)
    end
    private_class_method :fault_token

    def self.clamp(text) = text.to_s[0, MAX]
    private_class_method :clamp
  end
end
