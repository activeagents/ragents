# frozen_string_literal: true

require "json"

module Ragents
  # Abstract base class for LLM providers.
  # Providers handle communication with LLM APIs and normalize responses.
  #
  # The recommended provider is RubyLLM, which gives access to 500+ models
  # across all major LLM providers (OpenAI, Anthropic, Gemini, Ollama, etc.)
  #
  # @example
  #   provider = Ragents::Providers::RubyLLM.new(model: "gpt-4o")
  #   response = provider.generate(messages: context.to_a, tools: tools)
  #
  class Provider
    class Error < StandardError; end
    class ConfigurationError < Error; end
    class APIError < Error
      attr_reader :status_code, :response_body

      def initialize(message, status_code: nil, response_body: nil)
        super(message)
        @status_code = status_code
        @response_body = response_body
      end
    end
    class RateLimitError < APIError; end
    class AuthenticationError < APIError; end

    attr_reader :config

    def initialize(**config)
      @config = default_config.merge(config)
      validate_config!
    end

    # Generate a response from the LLM
    # @param messages [Array<Hash>] The conversation messages
    # @param tools [Array<Tool>, ToolRegistry] Available tools
    # @param options [Hash] Provider-specific options
    # @return [Response] The generation response
    def generate(messages:, tools: [], **options)
      raise NotImplementedError, "#{self.class} must implement #generate"
    end

    # Stream a response from the LLM
    # @param messages [Array<Hash>] The conversation messages
    # @param tools [Array<Tool>, ToolRegistry] Available tools
    # @param options [Hash] Provider-specific options
    # @yield [chunk] Yields response chunks as they arrive
    # @return [Response] The complete generation response
    def stream(messages:, tools: [], **options, &block)
      raise NotImplementedError, "#{self.class} must implement #stream"
    end

    # Provider name identifier
    def name
      self.class.name.split("::").last.downcase.to_sym
    end

    protected

    def default_config
      {}
    end

    def validate_config!
      # Override in subclasses
    end

    def format_messages(messages)
      messages.map do |msg|
        msg = msg.to_h if msg.respond_to?(:to_h)
        msg.transform_keys(&:to_s)
      end
    end

    def format_tools(tools)
      case tools
      when ToolRegistry
        tools.to_json_schemas
      when Array
        tools.map(&:to_json_schema)
      else
        []
      end
    end
  end

  # Response from a provider generation
  class Response
    attr_reader :content, :tool_calls, :finish_reason, :usage, :raw_response

    def initialize(content: nil, tool_calls: nil, finish_reason: nil, usage: {}, raw_response: nil)
      @content = content
      @tool_calls = tool_calls || []
      @finish_reason = finish_reason
      @usage = usage
      @raw_response = raw_response
    end

    def has_tool_calls?
      !@tool_calls.empty?
    end

    def to_message
      Message.assistant(
        @content,
        tool_calls: @tool_calls.empty? ? nil : @tool_calls.map(&:to_h)
      )
    end

    def to_h
      {
        content: @content,
        tool_calls: @tool_calls,
        finish_reason: @finish_reason,
        usage: @usage
      }
    end
  end

  # Tool call representation
  class ToolCall
    attr_reader :id, :name, :arguments

    def initialize(id:, name:, arguments:)
      @id = id
      @name = name.to_sym
      @arguments = arguments.is_a?(String) ? JSON.parse(arguments) : arguments
    end

    def to_h
      {
        id: @id,
        name: @name.to_s,
        arguments: @arguments
      }
    end

    def symbolized_arguments
      @arguments.transform_keys(&:to_sym)
    end
  end
end

# Require provider implementations
require_relative "providers/ruby_llm"
require_relative "providers/test"
