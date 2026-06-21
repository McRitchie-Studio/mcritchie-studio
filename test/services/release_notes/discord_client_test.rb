require "test_helper"
require "minitest/mock"

module ReleaseNotes
  class DiscordClientTest < ActiveSupport::TestCase
    test "deliver converts transport errors into the typed DeliveryError" do
      client = DiscordClient.new("https://discord.test/webhook")

      [SocketError, Net::OpenTimeout, Errno::ECONNREFUSED].each do |transport_error|
        Net::HTTP.stub(:start, ->(*_args, **_kwargs, &_blk) { raise transport_error }) do
          assert_raises(DiscordClient::DeliveryError, "#{transport_error} must convert to DeliveryError") do
            client.deliver(content: "hi")
          end
        end
      end
    end
  end
end
