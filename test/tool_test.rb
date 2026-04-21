# frozen_string_literal: true

require "test_helper"

class ToolTest < Minitest::Test
  def test_basic_tool
    tool = Ragents::Tool.new(:greet) do
      description "Greet someone"
      parameter :name, type: :string, required: true
      execute { |name:| "Hello, #{name}!" }
    end

    assert_equal :greet, tool.name
    assert_equal "Greet someone", tool.description_text
  end

  def test_tool_execution
    tool = Ragents::Tool.new(:add) do
      description "Add two numbers"
      parameter :a, type: :integer, required: true
      parameter :b, type: :integer, required: true
      execute { |a:, b:| a + b }
    end

    result = tool.call(a: 2, b: 3)
    assert_equal 5, result
  end

  def test_parameter_coercion
    tool = Ragents::Tool.new(:test) do
      description "Test coercion"
      parameter :num, type: :integer, required: true
      parameter :flag, type: :boolean, required: true
      execute { |num:, flag:| { num: num, flag: flag } }
    end

    result = tool.call(num: "42", flag: "true")
    assert_equal 42, result[:num]
    assert_equal true, result[:flag]
  end

  def test_default_parameter
    tool = Ragents::Tool.new(:greet) do
      description "Greet someone"
      parameter :name, type: :string, required: true
      parameter :greeting, type: :string, default: "Hello"
      execute { |name:, greeting:| "#{greeting}, #{name}!" }
    end

    result = tool.call(name: "World")
    assert_equal "Hello, World!", result
  end

  def test_missing_required_parameter
    tool = Ragents::Tool.new(:greet) do
      description "Greet someone"
      parameter :name, type: :string, required: true
      execute { |name:| "Hello, #{name}!" }
    end

    assert_raises(ArgumentError) do
      tool.call({})
    end
  end

  def test_to_json_schema
    tool = Ragents::Tool.new(:search) do
      description "Search the web"
      parameter :query, type: :string, required: true, description: "Search query"
      parameter :limit, type: :integer, default: 10
      execute { |query:, limit:| "results" }
    end

    schema = tool.to_json_schema
    assert_equal "function", schema[:type]
    assert_equal "search", schema[:function][:name]
    assert_equal "Search the web", schema[:function][:description]
    assert_includes schema[:function][:parameters][:required], "query"
  end

  def test_to_anthropic_schema
    tool = Ragents::Tool.new(:search) do
      description "Search the web"
      parameter :query, type: :string, required: true
      execute { |query:| "results" }
    end

    schema = tool.to_anthropic_schema
    assert_equal "search", schema[:name]
    assert_equal "Search the web", schema[:description]
    assert_equal "object", schema[:input_schema][:type]
  end

  def test_tool_registry
    registry = Ragents::ToolRegistry.new

    registry.register(:greet) do
      description "Greet"
      parameter :name, type: :string, required: true
      execute { |name:| "Hello, #{name}!" }
    end

    registry.register(:farewell) do
      description "Say goodbye"
      parameter :name, type: :string, required: true
      execute { |name:| "Goodbye, #{name}!" }
    end

    assert_equal 2, registry.size
    assert registry.include?(:greet)
    assert_equal "Greet", registry[:greet].description_text
  end

  def test_registry_to_json_schemas
    registry = Ragents::ToolRegistry.new

    registry.register(:tool1) do
      description "Tool 1"
      execute { "result" }
    end

    registry.register(:tool2) do
      description "Tool 2"
      execute { "result" }
    end

    schemas = registry.to_json_schemas
    assert_equal 2, schemas.size
    assert_equal "tool1", schemas[0][:function][:name]
  end

  def test_ractor_safe_flag
    safe_tool = Ragents::Tool.new(:safe) do
      description "Safe tool"
      execute { "result" }
    end

    unsafe_tool = Ragents::Tool.new(:unsafe) do
      description "Unsafe tool"
      requires_main_thread!
      execute { "result" }
    end

    assert safe_tool.ractor_safe?
    refute unsafe_tool.ractor_safe?
  end
end
