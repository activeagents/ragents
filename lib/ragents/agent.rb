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
      # What the DSL defined, as defined: used on the main Ractor.
      attr_reader :defined_system_prompt, :defined_tools

      # Frozen, shareable copies of the same definitions: used inside other
      # Ractors, which may only read shareable class instance variables.
      attr_reader :ractor_system_prompt, :ractor_tools

      # DSL: Define the system prompt for this agent
      #
      # Besides the prompt itself, a shareable copy is kept for other Ractors:
      # a frozen copy of a string, or a Ractor.shareable_proc copy of a block
      # that keeps its self. A block that captures mutable state has no copy;
      # it works on the main Ractor and keeps the agent out of Ractors.
      def system_prompt(prompt = nil, &block)
        @defined_system_prompt = block_given? ? block : prompt
        prompt = @defined_system_prompt
        @system_prompt_unsafe_reason = nil
        @ractor_system_prompt =
          if prompt.is_a?(Proc)
            shared, _how, reason = Shareable.block(prompt)
            @system_prompt_unsafe_reason = "system_prompt block can't be shared: #{reason}".freeze if reason
            reason ? nil : shared
          else
            shared, reason = Shareable.value(prompt)
            @system_prompt_unsafe_reason = "system_prompt can't be shared: #{reason}".freeze if reason
            reason ? nil : shared
          end
      end

      # DSL: Define a tool for this agent
      def tool(name, &block)
        @defined_tools ||= ToolRegistry.new
        new_tool = @defined_tools.register(name, &block)
        refresh_ractor_tools!
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
        # The system prompt isn't inherited (resolved_system_prompt reads only
        # this class's), but tools are.
        reasons = []
        reasons << "#{agent_label(self)}: #{@system_prompt_unsafe_reason}" if @system_prompt_unsafe_reason
        ancestors.reverse_each do |klass|
          next unless klass.is_a?(Class) && klass <= Ragents::Agent

          klass.instance_variable_get(:@tool_unsafe_reasons)&.each { |r| reasons << "#{agent_label(klass)}: #{r}" }
        end
        reasons
      end

      # Raises RactorSafetyError (on the calling Ractor, before anything is
      # spawned) when this agent can't run in a Ractor.
      def ensure_ractor_safe!
        reasons = ractor_unsafe_reasons
        return if reasons.empty?

        raise RactorSafetyError, "#{name || inspect} can't run inside a Ractor:\n  - #{reasons.join("\n  - ")}"
      end

      # Get all inherited tools (their shareable copies inside other Ractors)
      def tools
        on_main = Ractor.current.equal?(Ractor.main)
        registry = ToolRegistry.new

        # Collect tools from ancestors (inheritance chain)
        ancestors.reverse.each do |klass|
          next unless klass.respond_to?(:defined_tools)

          unless on_main || klass.instance_variable_get(:@tool_unsafe_reasons).nil?
            raise RactorSafetyError, "#{agent_label(klass)} has tools that can't run inside a Ractor"
          end

          (on_main ? klass.defined_tools : klass.ractor_tools)&.each { |t| registry.register(t.name, t) }
        end

        registry
      end

      # Get resolved system prompt
      def resolved_system_prompt
        prompt =
          if Ractor.current.equal?(Ractor.main)
            defined_system_prompt
          else
            raise RactorSafetyError, "#{agent_label(self)}: #{@system_prompt_unsafe_reason}" if @system_prompt_unsafe_reason

            ractor_system_prompt
          end
        prompt.is_a?(Proc) ? prompt.call : prompt
      end

      private

      # Keep the shareable registry in step with the defined one.
      def refresh_ractor_tools!
        reasons = @defined_tools.ractor_unsafe_reasons
        if reasons.empty?
          registry = ToolRegistry.new
          @defined_tools.each { |t| registry.register(t.name, t.ractor_copy) }
          @ractor_tools = Ractor.make_shareable(registry)
          @tool_unsafe_reasons = nil
        else
          @ractor_tools = nil
          @tool_unsafe_reasons = Ractor.make_shareable(reasons)
        end
      end

      def agent_label(klass) = klass.name || klass.inspect
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
        messages: [ Message.system(system) ] + @context.messages.to_a,
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
