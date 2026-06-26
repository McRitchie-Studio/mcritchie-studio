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

    test "deliver posts an embeds-only body, omitting the content key" do
      body = capture_delivery_body { |client| client.deliver(embeds: [{ title: "Card", color: 123 }]) }

      assert_equal [{ "title" => "Card", "color" => 123 }], body["embeds"]
      assert_not body.key?("content"), "an embeds-only delivery must not send an empty content key"
    end

    test "deliver still posts a content-only body (backward compatible)" do
      body = capture_delivery_body { |client| client.deliver(content: "plain text") }

      assert_equal "plain text", body["content"]
      assert_not body.key?("embeds"), "a content-only delivery must not send an empty embeds key"
    end

    test "deliver posts both content and embeds when given both" do
      body = capture_delivery_body { |client| client.deliver(content: "hi", embeds: [{ title: "Card" }]) }

      assert_equal "hi", body["content"]
      assert_equal [{ "title" => "Card" }], body["embeds"]
    end

    private

    # Run a single delivery against a stubbed transport and return the parsed JSON
    # request body, so a test can assert exactly what was POSTed to Discord.
    def capture_delivery_body
      client = DiscordClient.new("https://discord.test/webhook")
      captured = nil

      ok = Net::HTTPOK.new("1.1", "200", "OK")
      ok.instance_variable_set(:@body, "ok")
      ok.instance_variable_set(:@read, true)
      http = Object.new
      http.define_singleton_method(:request) do |request|
        captured = request.body
        ok
      end

      Net::HTTP.stub(:start, ->(*_args, **_kwargs, &blk) { blk.call(http) }) do
        yield client
      end

      JSON.parse(captured)
    end
  end
end
