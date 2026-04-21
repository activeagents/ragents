# frozen_string_literal: true

require "test_helper"

class ProviderTest < Minitest::Test
  def test_test_provider
    provider = Ragents::Providers::Test.new

    provider.stub_response(content: "Hello!")
    response = provider.generate(messages: [])

    assert_equal "Hello!", response.content
    assert provider.requests?
  end

  def test_test_provider_tool_call
    provider = Ragents::Providers::Test.new

    provider.stub_tool_call(
      name: :search,
      arguments: { query: "test" },
      id: "call_123"
    )

    response = provider.generate(messages: [])

    assert response.has_tool_calls?
    assert_equal 1, response.tool_calls.size
    assert_equal :search, response.tool_calls.first.name
    assert_equal "call_123", response.tool_calls.first.id
  end

  def test_test_provider_multiple_stubs
    provider = Ragents::Providers::Test.new

    provider.stub_response(content: "First")
    provider.stub_response(content: "Second")

    r1 = provider.generate(messages: [])
    r2 = provider.generate(messages: [])
    r3 = provider.generate(messages: []) # Uses default

    assert_equal "First", r1.content
    assert_equal "Second", r2.content
    assert_equal "Test response", r3.content
  end

  def test_test_provider_streaming
    provider = Ragents::Providers::Test.new
    provider.stub_response(content: "Hello")

    chunks = []
    response = provider.stream(messages: []) { |chunk| chunks << chunk }

    assert_equal "Hello", response.content
    assert_equal ["H", "e", "l", "l", "o"], chunks
  end

  def test_test_provider_request_tracking
    provider = Ragents::Providers::Test.new
    provider.stub_response(content: "OK")

    messages = [{ role: :user, content: "Test" }]
    provider.generate(messages: messages, temperature: 0.5)

    assert_equal 1, provider.requests.size
    assert_equal messages, provider.last_request[:messages]
    assert_equal 0.5, provider.last_request[:options][:temperature]
  end

  def test_test_provider_reset
    provider = Ragents::Providers::Test.new
    provider.stub_response(content: "Stub")
    provider.generate(messages: [])

    provider.reset!

    refute provider.requests?
    # Next call should use default
    response = provider.generate(messages: [])
    assert_equal "Test response", response.content
  end

  def test_response_to_message
    response = Ragents::Response.new(content: "Hello!")
    message = response.to_message

    assert message.is_a?(Ragents::Message)
    assert message.assistant?
    assert_equal "Hello!", message.content
  end

  def test_tool_call_symbolized_arguments
    tc = Ragents::ToolCall.new(
      id: "call_1",
      name: "test",
      arguments: { "key" => "value", "nested" => { "a" => 1 } }
    )

    args = tc.symbolized_arguments
    assert_equal "value", args[:key]
  end

  def test_tool_call_json_arguments
    tc = Ragents::ToolCall.new(
      id: "call_1",
      name: "test",
      arguments: '{"key": "value"}'
    )

    assert_equal "value", tc.arguments["key"]
  end
end
