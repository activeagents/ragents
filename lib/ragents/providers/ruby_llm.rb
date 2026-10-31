# frozen_string_literal: true

module Ragents
  module Providers
    # RubyLLM provider - uses the ruby_llm gem as the underlying LLM backend.
    # This gives access to 500+ models across all major providers:
    # OpenAI, Anthropic, Gemini, Bedrock, DeepSeek, Mistral, Ollama, and more.
    #
    # @see https://rubyllm.com/ for RubyLLM documentation
    #
    # @example Basic usage
    #   # First, configure RubyLLM (e.g., in an initializer)
    #   RubyLLM.configure do |config|
    #     config.openai_api_key = ENV["OPENAI_API_KEY"]
    #     config.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]
    #   end
    #
    #   # Then use with Ragents
    #   provider = Ragents::Providers::RubyLLM.new(model: "gpt-4o")
    #   agent = MyAgent.new(provider: provider)
    #
    # @example Using different models
    #   # OpenAI
    #   provider = Ragents::Providers::RubyLLM.new(model: "gpt-4o")
    #
    #   # Anthropic Claude
    #   provider = Ragents::Providers::RubyLLM.new(model: "claude-sonnet-4-20250514")
    #
    #   # Google Gemini
    #   provider = Ragents::Providers::RubyLLM.new(model: "gemini-2.0-flash")
    #
    #   # Local Ollama
    #   provider = Ragents::Providers::RubyLLM.new(model: "llama3.2")
    #
    class RubyLLM < Provider
      attr_reader :model

      def initialize(model: nil, **config)
        require_ruby_llm!
        super(**config)
        @model = model || @config[:model]
      end

      def generate(messages:, tools: [], **options)
        chat = build_chat(options)
        attach_tools(chat, tools)

        # Add all messages to the chat
        formatted_messages = format_messages_for_ruby_llm(messages)
        formatted_messages.each do |msg|
          chat.add_message(**msg)
        end

        # Complete the chat
        response = chat.complete
        parse_ruby_llm_response(response)
      end

      def stream(messages:, tools: [], **options, &block)
        chat = build_chat(options)
        attach_tools(chat, tools)

        formatted_messages = format_messages_for_ruby_llm(messages)
        formatted_messages.each do |msg|
          chat.add_message(**msg)
        end

        # Use RubyLLM streaming
        response = chat.complete do |chunk|
          block.call(chunk.content) if block_given? && chunk.content
        end

        parse_ruby_llm_response(response)
      end

      protected

      def default_config
        {
          model: "gpt-4o"
        }
      end

      def validate_config!
        # RubyLLM handles its own configuration validation
      end

      private

      def require_ruby_llm!
        require "ruby_llm"
      rescue LoadError
        raise ConfigurationError,
              "RubyLLM provider requires the 'ruby_llm' gem. Add `gem 'ruby_llm'` to your Gemfile."
      end

      def build_chat(options)
        model_name = options[:model] || @model
        ::RubyLLM.chat(model: model_name)
      end

      def attach_tools(chat, tools)
        return if tools.nil? || tools.empty?

        tool_list =
          case tools
          when ToolRegistry then tools.to_a
          when Array then tools
          else []
          end

        tool_list.each do |tool|
          ruby_llm_tool = build_ruby_llm_tool(tool)
          chat.with_tool(ruby_llm_tool)
        end
      end

      def build_ruby_llm_tool(ragent_tool)
        # Create a dynamic RubyLLM::Tool class for each Ragents tool
        tool_name = ragent_tool.name
        tool_desc = ragent_tool.description_text
        tool_params = ragent_tool.parameters
        tool_executor = ragent_tool.executor

        Class.new(::RubyLLM::Tool) do
          @tool_name = tool_name
          @tool_description = tool_desc
          @tool_params = tool_params
          @tool_executor = tool_executor

          class << self
            attr_reader :tool_name, :tool_description, :tool_params, :tool_executor
          end

          description tool_desc

          tool_params.each do |name, param|
            param name, type: ruby_llm_type(param.type), desc: param.description
          end

          define_method(:execute) do |**args|
            self.class.tool_executor.call(**args)
          end

          def self.ruby_llm_type(type)
            case type
            when :integer then :integer
            when :number then :number
            when :boolean then :boolean
            when :array then :array
            when :object then :object
            else :string
            end
          end
        end
      end

      def format_messages_for_ruby_llm(messages)
        messages.map do |msg|
          msg = msg.to_h if msg.respond_to?(:to_h)
          msg = msg.transform_keys(&:to_sym)

          result = {
            role: msg[:role].to_sym,
            content: msg[:content]
          }

          result[:tool_calls] = msg[:tool_calls] if msg[:tool_calls]
          result[:tool_call_id] = msg[:tool_call_id] if msg[:tool_call_id]

          result
        end
      end

      def parse_ruby_llm_response(response)
        content = response.content
        tool_calls = parse_tool_calls(response)

        Response.new(
          content: content,
          tool_calls: tool_calls,
          finish_reason: response.respond_to?(:finish_reason) ? response.finish_reason : "stop",
          usage: parse_usage(response),
          raw_response: response
        )
      end

      def parse_tool_calls(response)
        return [] unless response.respond_to?(:tool_calls) && response.tool_calls

        response.tool_calls.map do |tc|
          ToolCall.new(
            id: tc.id,
            name: tc.name,
            arguments: tc.arguments
          )
        end
      end

      def parse_usage(response)
        return {} unless response.respond_to?(:usage) && response.usage

        usage = response.usage
        {
          prompt_tokens: usage[:input_tokens] || usage[:prompt_tokens],
          completion_tokens: usage[:output_tokens] || usage[:completion_tokens],
          total_tokens: usage[:total_tokens]
        }.compact
      end
    end
  end
end
