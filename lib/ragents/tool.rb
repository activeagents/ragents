# frozen_string_literal: true

module Ragents
  # Tool definition for agent actions.
  # Tools are declarative definitions of callable functions that agents can invoke.
  #
  # @example
  #   tool = Ragents::Tool.new(:search_web) do
  #     description "Search the web for information"
  #     parameter :query, type: :string, required: true, description: "Search query"
  #     parameter :limit, type: :integer, default: 10
  #
  #     execute do |query:, limit:|
  #       # Search implementation
  #     end
  #   end
  #
  class Tool
    attr_reader :name, :description_text, :parameters, :executor

    # Why this tool can't run inside a Ractor (nil when it can).
    attr_reader :ractor_unsafe_reason

    # A frozen, shareable copy of this tool for use inside other Ractors, or
    # nil when it can't have one. The tool itself is left as defined, so it
    # behaves exactly the same on the main Ractor.
    attr_reader :ractor_copy

    # Instance variables the Tool itself manages; any others were set by the
    # tool's definition block.
    OWN_IVARS = %i[
      @name @description_text @parameters @executor @ractor_safe
      @ractor_unsafe_reason @ractor_copy @call_via_instance_exec @fresh_defaults
    ].freeze

    def initialize(name, &block)
      @name = name.to_sym
      @description_text = nil
      @parameters = {}
      @executor = nil
      @ractor_safe = true

      instance_eval(&block) if block_given?

      validate!
      freeze_for_ractor!
      build_ractor_copy!
    end

    # DSL: Set description
    def description(text)
      @description_text = text
    end

    # DSL: Define a parameter
    def parameter(name, type:, required: false, description: nil, default: nil, enum: nil)
      @parameters[name.to_sym] = Parameter.new(
        name: name.to_sym,
        type: type,
        required: required,
        description: description,
        default: default,
        enum: enum
      )
    end

    # DSL: Define the execution block
    def execute(&block)
      @executor = block
    end

    # DSL: Mark as requiring main thread (not Ractor-safe)
    def requires_main_thread!
      @ractor_safe = false
      @ractor_unsafe_reason ||= "is marked requires_main_thread!"
      @ractor_copy = nil
    end

    # True when the tool (and its execute block) can be used from any Ractor.
    def ractor_safe?
      @ractor_safe && @ractor_unsafe_reason.nil?
    end

    # Call the tool with arguments
    def call(**args)
      validated_args = validate_and_coerce_args(args)
      if @call_via_instance_exec
        instance_exec(**validated_args, &@executor)
      else
        @executor.call(**validated_args)
      end
    end

    # Generate JSON Schema for this tool (OpenAI function format)
    def to_json_schema
      {
        type: "function",
        function: {
          name: @name.to_s,
          description: @description_text,
          parameters: parameters_schema
        }
      }
    end

    # Generate Anthropic tool format
    def to_anthropic_schema
      {
        name: @name.to_s,
        description: @description_text,
        input_schema: parameters_schema
      }
    end

    # Parameters as JSON Schema object
    def parameters_schema
      required_params = @parameters.select { |_, p| p.required }.keys.map(&:to_s)

      {
        type: "object",
        properties: @parameters.transform_values(&:to_json_schema).transform_keys(&:to_s),
        required: required_params
      }
    end

    private

    def validate!
      raise ArgumentError, "Tool must have a name" if @name.nil? || @name.to_s.empty?
      raise ArgumentError, "Tool must have an executor" if @executor.nil?
    end

    def freeze_for_ractor!
      @name.freeze
      @description_text&.freeze
      @parameters.freeze
      @parameters.each_value(&:freeze)
    end

    # Builds the shareable copy that agents running in other Ractors use. It
    # copies the definition (name, description, parameters with their own
    # copies of defaults and enums) and replaces the execute block with a
    # Ractor.shareable_proc that is run with the copy as self. A tool can't
    # have a copy when its execute block assigns instance variables (the copy
    # is frozen), when its definition block left mutable state in instance
    # variables, or when the execute block captures mutable outer state.
    def build_ractor_copy!
      return unless @ractor_safe

      extra = instance_variables - OWN_IVARS
      mutable = extra.reject { |ivar| Ractor.shareable?(instance_variable_get(ivar)) }
      return ractor_unsafe!("keeps mutable state in #{mutable.join(", ")}") if mutable.any?

      writes = Shareable.ivar_writes(@executor)
      return ractor_unsafe!("execute block assigns #{writes.join(", ")}") if writes.any?

      executor, how, reason = Shareable.block(@executor, owner: self)
      return ractor_unsafe!("execute block can't be shared: #{reason}") if reason

      copy = self.class.allocate
      {
        :@name => @name,
        :@description_text => Shareable.deep_dup(@description_text),
        :@parameters => @parameters.transform_values(&:shareable_copy),
        :@executor => executor,
        :@call_via_instance_exec => how == :instance_exec,
        :@fresh_defaults => true,
        :@ractor_safe => true
      }.each { |ivar, value| copy.instance_variable_set(ivar, value) }
      extra.each { |ivar| copy.instance_variable_set(ivar, instance_variable_get(ivar)) }
      @ractor_copy = Ractor.make_shareable(copy)
    rescue Ractor::Error, TypeError, ArgumentError => e
      ractor_unsafe!("can't be made shareable: #{e.message}")
    end

    def ractor_unsafe!(reason)
      @ractor_unsafe_reason = reason.freeze
      @ractor_copy = nil
    end

    def validate_and_coerce_args(args)
      result = {}

      @parameters.each do |name, param|
        if args.key?(name)
          result[name] = param.coerce(args[name])
        elsif param.default
          # The Ractor copy's defaults are frozen; each call gets its own.
          result[name] = @fresh_defaults ? Shareable.deep_dup(param.default) : param.default
        elsif param.required
          raise ArgumentError, "Missing required parameter: #{name}"
        end
      end

      result
    end

    # Parameter definition
    class Parameter
      attr_reader :name, :type, :required, :description, :default, :enum

      TYPE_MAP = {
        string: "string",
        integer: "integer",
        number: "number",
        boolean: "boolean",
        array: "array",
        object: "object"
      }.freeze

      def initialize(name:, type:, required: false, description: nil, default: nil, enum: nil)
        @name = name
        @type = type.to_sym
        @required = required
        @description = description
        @default = default
        @enum = enum

        validate_type!
      end

      # A frozen copy that shares nothing mutable with this parameter.
      def shareable_copy
        Ractor.make_shareable(
          Parameter.new(
            name: @name, type: @type, required: @required,
            description: Shareable.deep_dup(@description),
            default: Shareable.deep_dup(@default),
            enum: Shareable.deep_dup(@enum)
          )
        )
      end

      def to_json_schema
        schema = { type: TYPE_MAP[@type] }
        schema[:description] = @description if @description
        schema[:enum] = @enum if @enum
        schema[:default] = @default if @default
        schema
      end

      def coerce(value)
        case @type
        when :string
          value.to_s
        when :integer
          Integer(value)
        when :number
          Float(value)
        when :boolean
          coerce_boolean(value)
        when :array
          Array(value)
        when :object
          value.is_a?(Hash) ? value : raise(ArgumentError, "Expected Hash for #{@name}")
        else
          value
        end
      end

      private

      def validate_type!
        unless TYPE_MAP.key?(@type)
          raise ArgumentError, "Invalid type: #{@type}. Must be one of: #{TYPE_MAP.keys.join(", ")}"
        end
      end

      def coerce_boolean(value)
        case value
        when true, "true", "1", 1
          true
        when false, "false", "0", 0
          false
        else
          raise ArgumentError, "Cannot coerce #{value.inspect} to boolean"
        end
      end
    end
  end

  # Registry of tools that can be shared across agents
  class ToolRegistry
    include Enumerable

    def initialize
      @tools = {}
    end

    def register(name = nil, tool = nil, &block)
      if block_given?
        tool = Tool.new(name, &block)
      elsif tool.nil?
        raise ArgumentError, "Must provide a Tool or a block"
      end

      @tools[tool.name] = tool
    end

    def [](name)
      @tools[name.to_sym]
    end

    def include?(name)
      @tools.key?(name.to_sym)
    end

    def each(&block)
      @tools.values.each(&block)
    end

    def to_a
      @tools.values
    end

    def to_json_schemas
      @tools.values.map(&:to_json_schema)
    end

    def to_anthropic_schemas
      @tools.values.map(&:to_anthropic_schema)
    end

    def ractor_safe?
      @tools.each_value.all?(&:ractor_safe?)
    end

    # @return [Array<String>] one line per tool that can't run in a Ractor
    def ractor_unsafe_reasons
      @tools.each_value.reject(&:ractor_safe?).map { |t| "tool :#{t.name} #{t.ractor_unsafe_reason}".freeze }
    end

    def size
      @tools.size
    end

    def empty?
      @tools.empty?
    end

    def freeze
      @tools.freeze
      @tools.each_value(&:freeze)
      super
    end
  end
end
