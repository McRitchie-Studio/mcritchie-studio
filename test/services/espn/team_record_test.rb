require "test_helper"

# [unit] Espn::TeamRecord answers ONE error for a read it could not make: a
# caller (X::PostDraft, Tiktok::ClipCaption) refuses on Espn::TeamRecord::Error
# and nothing else, so a TLS failure, a dropped connection or a timeout that
# escaped as its own class reached the operator as a 500. The network is
# stubbed: nothing here reaches ESPN.
class Espn::TeamRecordTest < ActiveSupport::TestCase
  NETWORK_FAILURES = [
    OpenSSL::SSL::SSLError.new("SSL_connect returned=1 errno=0"), EOFError.new("end of file reached"),
    Net::OpenTimeout.new("execution expired"), Net::ReadTimeout.new, Errno::ECONNRESET.new, Errno::ECONNREFUSED.new,
    SocketError.new("getaddrinfo: nodename nor servname provided"), Net::HTTPBadResponse.new("wrong status line"),
    Net::HTTPHeaderSyntaxError.new("wrong header line"), Net::ProtocolError.new("protocol"), Zlib::DataError.new("incorrect header check"),
    IOError.new("closed stream")
  ].freeze

  NETWORK_FAILURES.each do |boom|
    test "the real reader turns #{boom.class} into Espn::TeamRecord::Error" do
      error = Net::HTTP.stub(:start, ->(*, **) { raise boom }) do
        assert_raises(Espn::TeamRecord::Error) { Espn::TeamRecord.new(team_name: "Buffalo Bills").call }
      end

      assert_match(/could not read ESPN/, error.message)
      assert_includes error.message, boom.class.name
    end

    test "an injected reader that raises #{boom.class} is the same refusal" do
      error = assert_raises(Espn::TeamRecord::Error) do
        Espn::TeamRecord.new(team_name: "Buffalo Bills", fetch: ->(_url) { raise boom }).call
      end

      assert_match(/could not read ESPN/, error.message)
    end
  end

  test "a bug in the reader is not dressed up as a network failure" do
    assert_raises(NoMethodError) do
      Espn::TeamRecord.new(team_name: "Buffalo Bills", fetch: ->(_url) { nil.fetch("id") }).call
    end
  end
end
