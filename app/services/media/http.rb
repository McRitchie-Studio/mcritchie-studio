require "net/http"
require "openssl"

module Media
  # How a chat medium's HTTP send failed, sorted for a send with no idempotency
  # key (Media::Slack::Client, Media::Teams::Client):
  #
  #   NEVER_SENT  the connection never opened (DNS, refused, connect timeout):
  #               no byte reached the medium, so the send is provably not made.
  #   MAYBE_SENT  a timeout or dropped connection after the request went out,
  #               or a TLS error (OpenSSL raises SSLError for a peer that drops
  #               mid-response too, "SSL_read: unexpected eof"): it may have
  #               been made, so it is never blind-retried.
  module Http
    NEVER_SENT = [ SocketError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH,
                   Net::OpenTimeout ].freeze
    MAYBE_SENT = [ OpenSSL::SSL::SSLError, Net::ReadTimeout, Net::WriteTimeout, Timeout::Error, EOFError, IOError,
                   Errno::ECONNRESET, Errno::EPIPE, SystemCallError ].freeze
  end
end
