# frozen_string_literal: true

require "test_helper"

class AgentTest < Minitest::Test
  def setup
    @provider = build_test_provider
  end

  def test_basic_agent_class
    agent_class = Class.new(Ragents::Agent) do
      system_prompt "You are a helpful assistant."
    end

    agent = agent_class.new(provider: @provider)
    assert_equal "You are a helpful assistant.", agent.context.system_message.content
  end

  def test_agent_with_dynamic_system_prompt
    counter = 0
    agent_class = Class.new(Ragents::Agent) do
      system_prompt -> { "Prompt #{counter += 1}" }
    end

    agent1 = agent_class.new(provider: @provider)
    agent2 = agent_class.new(provider: @provider)

    # Each agent should get a fresh prompt evaluation
    assert_match(/Prompt \d/, agent1.context.system_message.content)
  end

  def test_agent_with_tools
    agent_class = Class.new(Ragents::Agent) do
      system_prompt "You are a calculator."

      tool :add do
        description "Add two numbers"
        parameter :a, type: :integer, required: true
        parameter :b, type: :integer, required: true
        execute { |a:, b:| (a + b).to_s }
      end
    end

    agent = agent_class.new(provider: @provider)
    assert_equal 1, agent.tools.size
    assert agent.tools.include?(:add)
  end

  def test_agent_run_simple
    @provider.stub_response(content: "Hello!")

    agent_class = Class.new(Ragents::Agent) do
      system_prompt "You are friendly."
    end

    agent = agent_class.new(provider: @provider)
    result = agent.run(input: "Hi")

    assert_equal 3, result.size # system + user + assistant
    assert_equal "Hello!", result.last_message.content
  end

  def test_agent_run_with_tool_call
    agent_class = Class.new(Ragents::Agent) do
      system_prompt "You are a calculator."

      tool :add do
        description "Add two numbers"
        parameter :a, type: :integer, required: true
        parameter :b, type: :integer, required: true
        execute { |a:, b:| (a + b).to_s }
      end
    end

    # First response: tool call
    @provider.stub_tool_call(name: :add, arguments: { a: 2, b: 3 })
    # Second response: final answer
    @provider.stub_response(content: "The answer is 5")

    agent = agent_class.new(provider: @provider)
    result = agent.run(input: "Add 2 and 3")

    # system + user + assistant(tool_call) + tool_result + assistant(final)
    assert_equal 5, result.size
    assert_equal "The answer is 5", result.last_message.content
  end

  def test_agent_say_chaining
    @provider.stub_response(content: "Response 1")
    @provider.stub_response(content: "Response 2")

    agent_class = Class.new(Ragents::Agent)
    agent = agent_class.new(provider: @provider)

    agent.say("First message")
    assert_equal 1, agent.context.size

    agent.run
    assert_equal 2, agent.context.size
    assert_equal "Response 1", agent.last_response
  end

  def test_agent_max_iterations
    agent_class = Class.new(Ragents::Agent) do
      tool :loop do
        description "A tool that loops"
        execute { "loop again" }
      end
    end

    # Always return a tool call
    20.times { @provider.stub_tool_call(name: :loop, arguments: {}) }

    agent = agent_class.new(provider: @provider, max_iterations: 3)

    assert_raises(Ragents::MaxIterationsError) do
      agent.run(input: "Start looping")
    end
  end

  def test_agent_inherits_tools
    parent_class = Class.new(Ragents::Agent) do
      tool :parent_tool do
        description "From parent"
        execute { "parent" }
      end
    end

    child_class = Class.new(parent_class) do
      tool :child_tool do
        description "From child"
        execute { "child" }
      end
    end

    agent = child_class.new(provider: @provider)
    assert_equal 2, agent.tools.size
    assert agent.tools.include?(:parent_tool)
    assert agent.tools.include?(:child_tool)
  end

  def test_agent_with_initial_context
    @provider.stub_response(content: "Continuing...")

    agent_class = Class.new(Ragents::Agent)

    initial_context = Ragents::Context.new(messages: [
      Ragents::Message.user("Previous message"),
      Ragents::Message.assistant("Previous response")
    ])

    agent = agent_class.new(provider: @provider, context: initial_context)
    result = agent.run(input: "Continue")

    assert_equal 4, result.size
  end
end
