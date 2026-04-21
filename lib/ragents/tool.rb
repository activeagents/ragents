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

    def initialize(name, &block)
      @name = name.to_sym
      @description_text = nil
      @parameters = {}
      @executor = nil
      @ractor_safe = true

      instance_eval(&block) if block_given?

      validate!
      freeze_for_ractor!
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
    end

    def ractor_safe?
      @ractor_safe
    end

    # Call the tool with arguments
    def call(**args)
      validated_args = validate_and_coerce_args(args)
      @executor.call(**validated_args)
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

    def validate_and_coerce_args(args)
      result = {}

      @parameters.each do |name, param|
        if args.key?(name)
          result[name] = param.coerce(args[name])
        elsif param.default
          result[name] = param.default
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
