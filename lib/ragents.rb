# frozen_string_literal: true

require_relative "ragents/version"

# Ragents - A Ractor-based AI agent framework
#
# Ragents provides concurrent, isolated agent execution using Ruby's Ractor
# primitive. It uses RubyLLM as the LLM backend, giving access to 500+ models
# across all major providers (OpenAI, Anthropic, Gemini, Ollama, etc.)
#
# @example Define and run an agent
#   class MyAgent < Ragents::Agent
#     system_prompt "You are a helpful assistant."
#
#     tool :greet do
#       description "Greet someone by name"
#       parameter :name, type: :string, required: true
#       execute { |name:| "Hello, #{name}!" }
#     end
#   end
#
#   # Configure RubyLLM first
#   RubyLLM.configure do |config|
#     config.openai_api_key = ENV["OPENAI_API_KEY"]
#   end
#
#   provider = Ragents::Providers::RubyLLM.new(model: "gpt-4o")
#   agent = MyAgent.new(provider: provider)
#   result = agent.run(input: "Greet the user named Alice")
#
module Ragents
  class Error < StandardError; end

  class << self
    attr_accessor :configuration

    def configure
      self.configuration ||= Configuration.new
      yield(configuration) if block_given?
      configuration
    end

    # Execute a block on the main thread from within a Ractor
    # This is used for operations that can't run in Ractors
    def execute_on_main(&block)
      if Ractor.current == Ractor.main
        block.call
      else
        raise Error, "Main thread execution from Ractor requires setup of main_executor"
      end
    end

    # Default provider registry
    def providers
      @providers ||= {}
    end

    def register_provider(name, provider)
      providers[name.to_sym] = provider
    end

    def provider(name)
      providers[name.to_sym]
    end
  end

  # Configuration class for Ragents
  class Configuration
    attr_accessor :default_provider, :max_iterations, :timeout, :default_model

    def initialize
      @default_provider = nil
      @default_model = "gpt-4o"
      @max_iterations = 10
      @timeout = 120
    end

    # Configure and register a provider
    # @param model [String] The model to use (e.g., "gpt-4o", "claude-sonnet-4-20250514")
    def provider(model: nil)
      model ||= @default_model
      provider = Providers::RubyLLM.new(model: model)
      Ragents.register_provider(:default, provider)
      provider
    end
  end
end

# Core components
require_relative "ragents/shareable"
require_relative "ragents/message"
require_relative "ragents/context"
require_relative "ragents/tool"
require_relative "ragents/provider"
require_relative "ragents/agent"
require_relative "ragents/orchestrator"

# Optional Rails integration (only loaded if Rails is present)
if defined?(Rails::Railtie)
  require_relative "ragents/railtie"
end
