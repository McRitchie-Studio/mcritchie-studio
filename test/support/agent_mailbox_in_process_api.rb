# Quacks like AgentApi for AgentApi.call, answering through an integration
# test's own session: the mailbox CLIs' real paths, bodies and error handling,
# against the real API in process. Nothing reaches the production board.
class AgentMailboxInProcessApi
  Response = Struct.new(:code, :body)

  def initialize(test, token)
    @test = test
    @token = token
  end

  def base_url = "http://www.example.com"
  def held_session(**) = nil
  def token = @token
  def invalidate_token! = nil

  def http_json(method, path, body, bearer:)
    headers = { "Authorization" => "Bearer #{bearer}" }
    if method == :get
      @test.get path, headers: headers
    else
      @test.post path, params: body, headers: headers, as: :json
    end
    Response.new(@test.response.status.to_s, @test.response.body)
  end
end
