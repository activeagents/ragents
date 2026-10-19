# frozen_string_literal: true

require "test_helper"
require "support/fake_openai_server"

class OpenAICompatibleTest < Minitest::Test
  class EchoAgent < Ragents::Agent
    system_prompt "You echo."

    tool :echo do
      description "Echo the text"
      parameter :text, type: :string, required: true
      execute { |text:| "tool saw #{text}" }
    end
  end

  def setup
    @server = FakeOpenAIServer.new
    @provider = provider
  end

  def teardown
    @server.stop
  end

  def provider(**options)
    Ragents::Providers::OpenAICompatible.new(model: "fake-model", base_url: @server.base_url, api_key: "sk-test", **options)
  end

  def test_provider_is_frozen_and_shareable
    assert Ractor.shareable?(@provider)
    assert_equal "fake-model", @provider.model
  end

  def test_generate_sends_messages_tools_and_headers
    response = @provider.generate(messages: [ { role: "user", content: "hi" } ], tools: EchoAgent.tools)

    assert_predicate response, :has_tool_calls?
    assert_equal :echo, response.tool_calls.first.name
    assert_equal({ "text" => "hi" }, response.tool_calls.first.arguments)

    request = @server.received.last
    assert_equal "/v1/chat/completions", request[:path]
    assert_equal "Bearer sk-test", request[:headers]["authorization"]
    assert_equal "echo", request[:body].dig("tools", 0, "function", "name")
  end

  def test_runs_an_agent_with_tool_calls_on_main
    context = EchoAgent.new(provider: @provider).run(input: "hello")

    assert_equal "tool saw hello", context.messages[3].content
    assert_equal "echo: hello", context.last_message.content
    # The tool result went back to the model with its call id.
    tool_message = @server.received.last[:body]["messages"].find { |m| m["role"] == "tool" }
    assert_equal "call_1", tool_message["tool_call_id"]
  end

  def test_runs_an_agent_inside_a_ractor
    context = EchoAgent.run_in_ractor(provider: @provider, input: "from a ractor")

    assert_equal "echo: from a ractor", context.last_message.content
    assert_equal "tool saw from a ractor", context.messages[3].content
  end

  def test_runs_agents_in_a_pool
    pool = Ragents::Pool.new(size: 2, threads: 2)
    jobs = Array.new(6) { |i| pool.submit(EchoAgent, provider: @provider, input: "job #{i}") }

    assert_equal (0..5).map { |i| "echo: job #{i}" }, jobs.map { |j| j.value.last_message.content }
  ensure
    pool&.shutdown
  end

  def test_keeps_connections_alive_per_ractor
    3.times { @provider.generate(messages: [ { role: "user", content: "x" } ]) }
    assert_equal 1, @server.connections

    Ractor.new(@provider) { |p| 3.times { p.generate(messages: [ { role: "user", content: "y" } ]) } }.join
    assert_equal 2, @server.connections
  end

  def test_retries_once_when_a_kept_alive_connection_was_closed
    @server.stop
    @server = FakeOpenAIServer.new(close_after_response: true)
    provider = provider()

    3.times { |i| assert_equal "echo: #{i}", provider.generate(messages: [ { role: "user", content: i.to_s } ]).content }
    assert_equal 3, @server.connections
  end

  def test_streams_text_deltas_and_usage
    deltas = []
    response = @provider.stream(messages: [ { role: "user", content: "one two three" } ]) { |d| deltas << d }

    assert_equal [ "one ", "two ", "three " ], deltas
    assert_equal "one two three ", response.content
    assert_equal "stop", response.finish_reason
    assert_equal 3, response.usage["completion_tokens"]
  end

  def test_streams_inside_a_pool_back_to_the_caller
    pool = Ragents::Pool.new(size: 1)
    deltas = []
    content = pool.call(StreamJob, :run, @provider, "a b c") { |d| deltas << d }

    assert_equal [ "a ", "b ", "c " ], deltas
    assert_equal "a b c ", content
  ensure
    pool&.shutdown
  end

  module StreamJob
    def self.run(provider, text, &emit)
      provider.stream(messages: [ { role: "user", content: text } ], &emit).content
    end
  end

  def test_maps_http_errors
    assert_raises(Ragents::Provider::AuthenticationError) { provider_for("status-401").generate(messages: []) }
    assert_raises(Ragents::Provider::RateLimitError) { provider_for("status-429").generate(messages: []) }
    error = assert_raises(Ragents::Provider::APIError) { provider_for("status-500").generate(messages: []) }
    assert_equal 500, error.status_code
  end

  def provider_for(model)
    Ragents::Providers::OpenAICompatible.new(model: model, base_url: @server.base_url, api_key: nil)
  end

  def test_no_authorization_header_without_a_key
    provider_for("fake-model").generate(messages: [ { role: "user", content: "x" } ])
    refute @server.received.last[:headers].key?("authorization")
  end

  def test_openrouter_preset_adds_usage_accounting
    openrouter = Ragents::Providers::OpenAICompatible.openrouter(model: "some/model", api_key: "k", base_url: @server.base_url)
    openrouter.generate(messages: [ { role: "user", content: "x" } ])

    assert_equal({ "include" => true }, @server.received.last[:body]["usage"])
  end

  def test_config_is_copied_not_frozen
    headers = { "X-Title" => "ragents" }
    provider(headers: headers)
    refute_predicate headers, :frozen?
  end

  def test_requires_a_model
    assert_raises(Ragents::Provider::ConfigurationError) do
      Ragents::Providers::OpenAICompatible.new(model: "", base_url: @server.base_url)
    end
  end
end
