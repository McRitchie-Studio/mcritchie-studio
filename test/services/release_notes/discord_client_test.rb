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

    test "[unit] a payload inside every limit is still one message" do
      bodies = DiscordClient.messages(content: "# header", embeds: [{ title: "Card" }])

      assert_equal [{ content: "# header", embeds: [{ title: "Card" }] }], bodies
    end

    test "[unit] discord_length counts UTF-16 units, so an emoji costs two" do
      assert_equal 2, DiscordClient.discord_length("🚀")
      assert_equal 3, DiscordClient.discord_length("a🚀")
    end

    test "[unit] a single line longer than the cap is hard-split, never sent whole" do
      bodies = DiscordClient.messages(content: "x" * 4500)

      assert_equal [2000, 2000, 500], bodies.map { |b| b[:content].length }
    end

    test "[unit] more than 10 embeds split into batches of at most 10" do
      embeds = (1..23).map { |i| { title: "Card #{i}" } }
      bodies = DiscordClient.messages(content: "# header", embeds: embeds)

      assert_equal [10, 10, 3], bodies.map { |b| b[:embeds].size }
      assert_equal "# header", bodies.first[:content], "the header leads the first message"
      assert_nil bodies.second[:content]
      assert_equal embeds.map { |e| e[:title] }, bodies.flat_map { |b| b[:embeds] }.map { |e| e[:title] }
    end

    test "[unit] embeds split before their summed text passes 6000 characters" do
      embeds = (1..4).map { |i| { title: "Card #{i}", description: "d" * 2000 } }
      bodies = DiscordClient.messages(embeds: embeds)

      assert_equal [2, 2], bodies.map { |b| b[:embeds].size }
      bodies.each do |body|
        total = body[:embeds].sum { |e| DiscordClient.embed_length(e) }
        assert_operator total, :<=, DiscordClient::EMBED_CHARS_PER_MESSAGE
      end
    end

    test "[unit] embed fields and footer count toward the 6000 total" do
      embed = { title: "t", footer: { text: "f" * 10 }, fields: [{ name: "n" * 5, value: "v" * 7 }] }

      assert_equal 23, DiscordClient.embed_length(embed)
    end

    test "[unit] an embed over its own title or description limit is clipped" do
      body = DiscordClient.messages(embeds: [{ title: "t" * 300, description: "d" * 5000 }]).first
      embed = body[:embeds].first

      assert_equal DiscordClient::EMBED_TITLE_LIMIT, embed[:title].length
      assert_equal DiscordClient::EMBED_DESCRIPTION_LIMIT, embed[:description].length
      assert embed[:title].end_with?("…")
    end

    test "[unit] a refused message raises with Discord's own error body and its position" do
      responses = [http_response(Net::HTTPOK, "200", "ok"),
                   http_response(Net::HTTPBadRequest, "400", '{"content": ["Must be 2000 or fewer in length."]}')]
      error = assert_raises(DiscordClient::DeliveryError) do
        with_responses(responses) { |client| client.deliver(content: "x" * 2500) }
      end

      assert_includes error.message, "HTTP 400"
      assert_includes error.message, "Must be 2000 or fewer in length."
      assert_includes error.message, "message 2 of 2 (1 already posted)"
    end

    test "[unit] a 429 is retried once after Discord's retry_after" do
      waited = []
      responses = [http_response(Net::HTTPTooManyRequests, "429", '{"retry_after": 1.5}'),
                   http_response(Net::HTTPOK, "200", "ok")]
      delivery = with_responses(responses, sleeper: ->(s) { waited << s }) { |client| client.deliver(content: "hi") }

      assert_equal [1.5], waited
      assert_equal 200, delivery.status
      assert_equal 1, delivery.messages
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

    def http_response(klass, code, body)
      response = klass.new("1.1", code, "")
      response.instance_variable_set(:@body, body)
      response.instance_variable_set(:@read, true)
      response
    end

    # Serve the given responses, one per POST, in order.
    def with_responses(responses, sleeper: ->(_s) { })
      client = DiscordClient.new("https://discord.test/webhook", sleeper: sleeper)
      queue = responses.dup
      http = Object.new
      http.define_singleton_method(:request) { |_request| queue.shift }
      Net::HTTP.stub(:start, ->(*_args, **_kwargs, &blk) { blk.call(http) }) do
        yield client
      end
    end
  end
end
