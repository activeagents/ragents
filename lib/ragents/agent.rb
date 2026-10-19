# frozen_string_literal: true

module Ragents
  # Base class for AI agents.
  # Agents can run in isolated Ractors for concurrent execution.
  #
  # @example Define an agent
  #   class ResearchAgent < Ragents::Agent
  #     system_prompt "You are a research assistant..."
  #
  #     tool :search_web do
  #       description "Search the web"
  #       parameter :query, type: :string, required: true
  #       execute { |query:| WebSearch.call(query) }
  #     end
  #   end
  #
  # @example Run an agent
  #   agent = ResearchAgent.new(provider: my_provider)
  #   result = agent.run(context: initial_context)
  #
  class Agent
    class << self
      attr_reader :defined_system_prompt, :defined_tools

      # DSL: Define the system prompt for this agent
      #
      # The prompt is stored Ractor-shareable (see Ragents::Shareable): a
      # string is kept as a frozen copy, and a block or lambda as a shareable
      # copy that keeps its self. A block that captures mutable state still
      # works on the main Ractor but keeps the agent out of Ractors.
      def system_prompt(prompt = nil, &block)
        prompt = block if block_given?
        @system_prompt_unsafe_reason = nil
        @defined_system_prompt =
          if prompt.is_a?(Proc)
            shared, _how, reason = Shareable.block(prompt)
            @system_prompt_unsafe_reason = "system_prompt block can't be shared: #{reason}" if reason
            shared
          else
            shared, reason = Shareable.value(prompt)
            @system_prompt_unsafe_reason = "system_prompt can't be shared: #{reason}" if reason
            shared
          end
      end

      # DSL: Define a tool for this agent
      #
      # The class's registry is replaced rather than mutated, so that once
      # every tool is shareable the registry itself can be frozen and read
      # from any Ractor.
      def tool(name, &block)
        new_tool = Tool.new(name, &block)
        registry = ToolRegistry.new
        defined_tools&.each { |t| registry.register(t.name, t) }
        registry.register(new_tool.name, new_tool)
        @defined_tools = registry.ractor_safe? ? Ractor.make_shareable(registry) : registry
        new_tool
      end

      # True when instances of this agent can be built and run inside a
      # non-main Ractor (run_async, run_in_ractor, Orchestrator#parallel,
      # Ragents::Pool).
      def ractor_safe?
        ractor_unsafe_reasons.empty?
      end

      # @return [Array<String>] what keeps this agent out of Ractors, if anything
      def ractor_unsafe_reasons
        ancestors.reverse.flat_map do |klass|
          next [] unless klass.is_a?(Class) && klass <= Ragents::Agent

          reasons = []
          reason = klass.instance_variable_get(:@system_prompt_unsafe_reason)
          reasons << "#{klass.name || klass.inspect}: #{reason}" if reason
          tools = klass.defined_tools
          tools&.ractor_unsafe_reasons&.each { |r| reasons << "#{klass.name || klass.inspect}: #{r}" }
          reasons
        end
      end

      # Raises RactorSafetyError (on the calling Ractor, before anything is
      # spawned) when this agent can't run in a Ractor.
      def ensure_ractor_safe!
        reasons = ractor_unsafe_reasons
        return if reasons.empty?

        raise RactorSafetyError, "#{name || inspect} can't run inside a Ractor:\n  - #{reasons.join("\n  - ")}"
      end

      # Get all inherited tools
      def tools
        registry = ToolRegistry.new

        # Collect tools from ancestors (inheritance chain)
        ancestors.reverse.each do |klass|
          next unless klass.respond_to?(:defined_tools) && klass.defined_tools

          klass.defined_tools.each { |t| registry.register(t.name, t) }
        end

        registry
      end

      # Get resolved system prompt
      def resolved_system_prompt
        prompt = defined_system_prompt
        prompt.is_a?(Proc) ? prompt.call : prompt
      end
    end

    attr_reader :provider, :context, :tools, :options

    def initialize(provider:, context: nil, tools: nil, **options)
      @provider = provider
      @context = context || Context.new
      @tools = tools || self.class.tools
      @options = options
      @max_iterations = options.fetch(:max_iterations, 10)

      setup_initial_context!
    end

    # Run the agent to completion (handles tool calls automatically)
    # @param input [String, Message, nil] Optional user input to add
    # @return [Context] The final context after all processing
    def run(input: nil)
      add_user_input!(input) if input

      iterations = 0
      loop do
        iterations += 1
        raise MaxIterationsError, "Exceeded #{@max_iterations} iterations" if iterations > @max_iterations

        response = generate
        @context = @context.add_message(response.to_message)

        break unless response.has_tool_calls?

        execute_tool_calls(response.tool_calls)
      end

      @context
    end

    # Run a single generation (does not auto-execute tools)
    # @return [Response] The provider response
    def generate
      @provider.generate(
        messages: @context.to_a,
        tools: @tools,
        **@options
      )
    end

    # Add a user message and return self for chaining
    # @param content [String] The user message
    # @return [self]
    def say(content)
      @context = @context.add_message(Message.user(content))
      self
    end

    # Get the last response content
    def last_response
      @context.last_assistant_message&.content
    end

    # Run the agent in a Ractor for isolated concurrent execution
    #
    # The provider is shared with the Ractor if it is shareable (see
    # Providers::OpenAICompatible) and copied otherwise; a copied provider's
    # state (e.g. a Test provider's stubs) is consumed in the copy.
    #
    # @param input [String, nil] Optional user input
    # @return [Ractor] The running Ractor
    # @raise [RactorSafetyError] if the agent's definition can't be shared
    def self.run_async(provider:, context: nil, input: nil, **options)
      ensure_ractor_safe!
      agent_class = self
      frozen_context = context&.freeze || Context.new.freeze

      begin
        Ractor.new(agent_class, provider, frozen_context, input, options) do |klass, prov, ctx, inp, opts|
          agent = klass.new(provider: prov, context: ctx, **opts)
          Ractor.make_shareable(agent.run(input: inp))
        end
      rescue StandardError => e
        # Ractor.new raises here (on the caller) only when an argument can't be
        # shared or copied into the new Ractor; the block's own errors surface
        # later from Ractor#value.
        raise RactorSafetyError, "can't send #{name || inspect}'s arguments into a Ractor (#{e.class}: #{e.message}). " \
                                 "The provider (#{provider.class}) and options must be shareable or copyable; " \
                                 "Providers::OpenAICompatible is shareable."
      end
    end

    # Execute in Ractor and wait for result
    # Uses Ruby 4.x Ractor#value (replaces deprecated #take)
    def self.run_in_ractor(provider:, context: nil, input: nil, **options)
      ractor = run_async(provider: provider, context: context, input: input, **options)
      ractor.value
    end

    private

    def setup_initial_context!
      system = self.class.resolved_system_prompt
      return unless system && @context.system_message.nil?

      @context = Context.new(
        messages: [Message.system(system)] + @context.messages.to_a,
        metadata: @context.metadata
      )
    end

    def add_user_input!(input)
      message = input.is_a?(Message) ? input : Message.user(input.to_s)
      @context = @context.add_message(message)
    end

    def execute_tool_calls(tool_calls)
      tool_calls.each do |tool_call|
        result = execute_tool(tool_call)
        @context = @context.add_message(
          Message.tool(
            result.to_s,
            tool_call_id: tool_call.id,
            name: tool_call.name.to_s
          )
        )
      end
    end

    def execute_tool(tool_call)
      tool = @tools[tool_call.name]

      unless tool
        return { error: "Unknown tool: #{tool_call.name}" }.to_json
      end

      begin
        result = tool.call(**tool_call.symbolized_arguments)
        result.is_a?(String) ? result : result.to_json
      rescue StandardError => e
        { error: e.message, type: e.class.name }.to_json
      end
    end
  end

  # Error raised when agent exceeds max iterations
  class MaxIterationsError < StandardError; end
end
