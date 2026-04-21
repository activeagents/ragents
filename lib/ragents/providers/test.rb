# frozen_string_literal: true

require "securerandom"

module Ragents
  module Providers
    # Test provider for unit testing without real API calls.
    # Allows scripting responses for predictable test scenarios.
    #
    # @example Basic stubbing
    #   provider = Ragents::Providers::Test.new
    #   provider.stub_response(content: "Hello!")
    #
    #   response = provider.generate(messages: [])
    #   response.content # => "Hello!"
    #
    # @example Stubbing tool calls
    #   provider = Ragents::Providers::Test.new
    #   provider.stub_tool_call(name: :search, arguments: { query: "test" })
    #   provider.stub_response(content: "Search complete")
    #
    #   # First call returns tool call, second returns final response
    #   response1 = provider.generate(messages: [])
    #   response1.has_tool_calls? # => true
    #
    #   response2 = provider.generate(messages: [])
    #   response2.content # => "Search complete"
    #
    class Test < Provider
      attr_reader :requests

      def initialize(**config)
        super
        @responses = []
        @requests = []
        @default_response = Response.new(content: "Test response")
      end

      # Stub the next response
      # @param content [String] The response content
      # @param tool_calls [Array] Optional tool calls
      # @param finish_reason [String] The finish reason
      # @return [self] For method chaining
      def stub_response(content: nil, tool_calls: nil, finish_reason: "stop")
        @responses << Response.new(
          content: content,
          tool_calls: tool_calls || [],
          finish_reason: finish_reason
        )
        self
      end

      # Stub a tool call response
      # @param name [Symbol] The tool name
      # @param arguments [Hash] The tool arguments
      # @param id [String] Optional tool call ID
      # @param content [String] Optional content alongside tool call
      # @return [self] For method chaining
      def stub_tool_call(name:, arguments: {}, id: nil, content: nil)
        tool_call = ToolCall.new(
          id: id || "call_#{SecureRandom.hex(8)}",
          name: name,
          arguments: arguments
        )
        stub_response(content: content, tool_calls: [tool_call], finish_reason: "tool_calls")
        self
      end

      # Set default response for when no stubs remain
      # @param response [Response] The default response
      def default_response=(response)
        @default_response = response
      end

      def generate(messages:, tools: [], **options)
        @requests << {
          messages: messages,
          tools: tools,
          options: options
        }

        @responses.shift || @default_response
      end

      def stream(messages:, tools: [], **options, &block)
        response = generate(messages: messages, tools: tools, **options)

        # Simulate streaming by yielding content character by character
        if block_given? && response.content
          response.content.each_char do |char|
            block.call(char)
          end
        end

        response
      end

      # Clear all stubs and requests
      def reset!
        @responses.clear
        @requests.clear
      end

      # Get the last request made
      # @return [Hash, nil] The last request or nil
      def last_request
        @requests.last
      end

      # Check if any requests were made
      # @return [Boolean]
      def requests?
        !@requests.empty?
      end

      # Get the number of requests made
      # @return [Integer]
      def request_count
        @requests.size
      end

      protected

      def validate_config!
        # No validation needed for test provider
      end
    end
  end
end
