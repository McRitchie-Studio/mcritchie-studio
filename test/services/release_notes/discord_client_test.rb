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

    # REGRESSION (rel-20260925-3b1f5c): 27 tasks fell back to the plain-text layout,
    # a 2790-character `content` against Discord's 2000 cap — Discord answered 400
    # and the notes never landed. Every message must fit, split on line boundaries.
    test "[unit] content over the 2000 cap is split on line boundaries across messages" do
      lines = (1..40).map { |i| "• [Task number #{i}](https://mcritchie.studio/tasks/task-number-#{i}-slug)" }
      content = "🚀 Production deployed: McRitchie Studio rel-x (abc1234)\n\n#{lines.join("\n")}"
      assert_operator DiscordClient.discord_length(content), :>, DiscordClient::CONTENT_LIMIT

      bodies = capture_delivery_bodies { |client| client.deliver(content: content) }

      assert_operator bodies.size, :>, 1
      bodies.each do |body|
        assert_operator DiscordClient.discord_length(body["content"]), :<=, DiscordClient::CONTENT_LIMIT
      end
      assert_equal content, bodies.map { |b| b["content"] }.join("\n"), "no line may be lost or reordered"
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

    # Every body POSTed in one delivery, in order.
    def capture_delivery_bodies
      client = DiscordClient.new("https://discord.test/webhook")
      captured = []
      http = Object.new
      http.define_singleton_method(:request) do |request|
        captured << JSON.parse(request.body)
        ok = Net::HTTPOK.new("1.1", "200", "OK")
        ok.instance_variable_set(:@body, "ok")
        ok.instance_variable_set(:@read, true)
        ok
      end

      Net::HTTP.stub(:start, ->(*_args, **_kwargs, &blk) { blk.call(http) }) do
        yield client
      end
      captured
    end
  end
end
