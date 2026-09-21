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

    # A SEPARATE, LARGER BOUND FOR TEXT WE WROTE. MAX exists to stop
    # vendor-controlled text of unbounded length; an authored message has a
    # length we chose, and clamping it to 120 cut every remedy mid-sentence
    # ("…it is not an "). The three authored messages measure 110-190 chars, so
    # this leaves headroom without becoming "unbounded by another name".
    AUTHORED_MAX = 400

    # A real fault token is one short identifier. The cap and the character
    # class together are the guard: a PEM header is rejected (it leads with
    # "-"), an address is rejected (no "@" in the class), and a base64 run is
    # cut off by the length bound long before it is a useful fragment.
    TOKEN = /\A[A-Za-z][A-Za-z0-9_]{0,31}\z/

    # ERRORS WE AUTHORED PASS THEIR MESSAGE THROUGH, clamped.
    #
    # The danger this class exists for is an exception that QUOTES ITS INPUT —
    # a vendor response body, a parser echoing the blob it choked on. Our own
    # raises quote nothing: their messages are strings we wrote, and each of the
    # three below was written to carry the REMEDY. Slugging them destroyed it.
    # Measured before this list existed:
    #
    #   UnregisteredSubject -> "…: refusing"   (lost: register, grant, then check)
    #   Malformed           -> "…: google"     (lost: the position AND the cause)
    #   Revoked             -> "…: x"          (lost: the reinstate command)
    #
    # An operator reading "refusing" has been told nothing. The leading-word
    # fallback is right for a foreign message and wrong for one of ours, so the
    # split is by ORIGIN, not by shape.
    # A CENTRAL FROZEN LIST, NOT A MARKER MODULE — and the third entry is when
    # that choice had to be made deliberately rather than by default. A marker
    # (`include Workspace::AuthoredError`) would be tidier and is the wrong
    # shape: this is a security ALLOW-LIST, not a taxonomy. A marker makes the
    # redaction bypass self-service — any author could opt their own message
    # past the redactor with no diff on THIS file, which is the file a security
    # reviewer watches — and `include` is inherited, so a subclass three levels
    # down would inherit the exemption silently. Adding a class here costs one
    # line and shows up in exactly the right diff.
    #
    # The load-time coupling (naming app classes in a class body) is the price.
    # If it ever bites, resolve by NAME at call time rather than loosening this.
    AUTHORED = [
      Workspace::Credentials::UnregisteredSubject,
      Workspace::Credentials::Malformed,
      WorkspaceAccount::Revoked,
      Workspace::DriveWalker::TooDeep
    ].freeze

    def self.for(error)
      return "unknown error" if error.nil?

      if AUTHORED.any? { |klass| error.is_a?(klass) }
        return "#{error.class}: #{error.message.to_s.scrub}"[0, AUTHORED_MAX]
      end

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
      # .scrub IS LOAD-BEARING, not defensive tidiness. A regex over a string
      # with invalid encoding raises ArgumentError: invalid byte sequence in
      # UTF-8 — and every caller of this method is INSIDE a rescue body, where
      # a raise is not caught by its own rescue. Measured: one garbled response
      # body (a truncated or proxy-intercepted read) took the ArgumentError
      # straight out of `checkable.map`, so the sweep printed NO failure line at
      # all, left the failing row `active` with `last_check_error: nil`, and
      # never checked the rows behind it. That is precisely the abandonment this
      # class exists to prevent, caused by the class itself.
      body = error.message.to_s.scrub
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
