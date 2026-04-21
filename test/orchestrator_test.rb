# frozen_string_literal: true

require "test_helper"

class OrchestratorTest < Minitest::Test
  def setup
    @provider = build_test_provider
  end

  def test_register_and_run_agent
    agent_class = Class.new(Ragents::Agent) do
      system_prompt "Test agent"
    end

    @provider.stub_response(content: "Agent response")

    orchestrator = Ragents::Orchestrator.new(provider: @provider)
    orchestrator.register(:test_agent, agent_class)

    result = orchestrator.run(:test_agent, input: "Hello")

    assert result.is_a?(Ragents::Context)
    assert_equal "Agent response", result.last_message.content
  end

  def test_unknown_agent_raises
    orchestrator = Ragents::Orchestrator.new(provider: @provider)

    assert_raises(ArgumentError) do
      orchestrator.run(:nonexistent, input: "Hello")
    end
  end

  def test_workflow_sequential
    agent1_class = Class.new(Ragents::Agent) do
      system_prompt "Agent 1"
    end

    agent2_class = Class.new(Ragents::Agent) do
      system_prompt "Agent 2"
    end

    @provider.stub_response(content: "Step 1 complete")
    @provider.stub_response(content: "Step 2 complete")

    orchestrator = Ragents::Orchestrator.new(provider: @provider)
    orchestrator.register(:step1, agent1_class)
    orchestrator.register(:step2, agent2_class)

    result = orchestrator.workflow do |w|
      w.step(:step1, input: "Start")
      w.step(:step2)
    end

    assert_equal "Step 2 complete", result.last_message.content
  end

  def test_workflow_with_dynamic_options
    agent_class = Class.new(Ragents::Agent)

    @provider.stub_response(content: "First result")
    @provider.stub_response(content: "Second result based on: First result")

    orchestrator = Ragents::Orchestrator.new(provider: @provider)
    orchestrator.register(:agent, agent_class)

    result = orchestrator.workflow do |w|
      w.step(:agent, input: "First step")
      w.step(:agent) { |ctx| { input: "Continue from: #{ctx.last_assistant_message.content}" } }
    end

    # The second request should have been built from the first result
    assert_equal 2, @provider.requests.size
  end

  def test_supervised_success
    agent_class = Class.new(Ragents::Agent)
    @provider.stub_response(content: "Success")

    orchestrator = Ragents::Orchestrator.new(provider: @provider)
    orchestrator.register(:agent, agent_class)

    result = orchestrator.supervised(:agent, input: "Test", max_restarts: 3)
    assert_equal "Success", result.last_message.content
  end

  def test_context_storage
    orchestrator = Ragents::Orchestrator.new(provider: @provider)

    ctx = Ragents::Context.new(messages: [user_message("Hello")])
    orchestrator.store_context(:session1, ctx)

    retrieved = orchestrator.fetch_context(:session1)
    assert_equal ctx, retrieved
  end

  def test_agent_with_default_options
    agent_class = Class.new(Ragents::Agent)
    @provider.stub_response(content: "OK")

    orchestrator = Ragents::Orchestrator.new(provider: @provider)
    orchestrator.register(:agent, agent_class, max_iterations: 5)

    # The agent should be created with max_iterations: 5
    result = orchestrator.run(:agent, input: "Test")
    assert result.is_a?(Ragents::Context)
  end
end
