# frozen_string_literal: true

require "test_helper"

# Agents must actually run inside non-main Ractors: their definitions are read
# from class instance variables, which Ruby 4.0 only allows for shareable
# values.
class RactorSafetyTest < Minitest::Test
  class EchoAgent < Ragents::Agent
    system_prompt "You echo."

    tool :echo do
      description "Echo the text, prefixed with the tool's name"
      parameter :text, type: :string, required: true
      # self is the Tool, on any Ractor
      execute { |text:| "#{name}:#{text}" }
    end
  end

  class LoudAgent < EchoAgent
    system_prompt { "I am #{name}" } # self is the agent class

    tool :shout do
      description "Upcase the text"
      parameter :text, type: :string, required: true
      execute { |text:| text.upcase }
    end
  end

  def test_agent_with_tools_runs_inside_a_ractor
    @provider.stub_tool_call(name: :echo, arguments: { text: "hi" })
    @provider.stub_response(content: "done")

    context = EchoAgent.run_in_ractor(provider: @provider, input: "go")

    assert_equal %i[system user assistant tool assistant], context.messages.map(&:role)
    assert_equal "echo:hi", context.messages[3].content
    assert_equal "done", context.last_message.content
    assert Ractor.shareable?(context)
  end

  def test_inherited_tools_and_dynamic_prompt_inside_a_ractor
    @provider.stub_tool_call(name: :shout, arguments: { text: "hi" })
    @provider.stub_tool_call(name: :echo, arguments: { text: "there" })
    @provider.stub_response(content: "done")

    context = LoudAgent.run_in_ractor(provider: @provider, input: "go")

    assert_equal "I am RactorSafetyTest::LoudAgent", context.system_message.content
    assert_equal [ "HI", "echo:there" ], context.messages.select(&:tool?).map(&:content)
  end

  def test_definitions_behave_the_same_on_the_main_ractor
    @provider.stub_tool_call(name: :echo, arguments: { text: "hi" })
    @provider.stub_response(content: "done")

    context = LoudAgent.new(provider: @provider).run(input: "go")

    assert_equal "I am RactorSafetyTest::LoudAgent", context.system_message.content
    assert_equal "echo:hi", context.messages[3].content
  end

  def test_ractors_get_shareable_copies_of_the_definitions
    assert_predicate EchoAgent, :ractor_safe?
    assert Ractor.shareable?(EchoAgent.ractor_tools)
    assert Ractor.shareable?(LoudAgent.ractor_system_prompt)
  end

  def test_definitions_on_the_main_ractor_are_left_as_defined
    tool = EchoAgent.defined_tools[:echo]

    refute_predicate tool, :frozen?
    refute Ractor.shareable?(tool.executor)
    # Providers that call the execute block directly (e.g. RubyLLM) still get
    # the tool as self.
    assert_equal "echo:direct", tool.executor.call(text: "direct")
  end

  def test_unfrozen_prompt_string_is_copied_not_frozen
    prompt = String.new("Mutable prompt")
    agent_class = Class.new(Ragents::Agent) { system_prompt prompt }

    refute_predicate prompt, :frozen?
    assert_same prompt, agent_class.defined_system_prompt
    assert Ractor.shareable?(agent_class.ractor_system_prompt)
    assert_predicate agent_class, :ractor_safe?
  end

  def test_parameter_defaults_keep_their_main_ractor_behaviour
    default_tags = [ "a" ]
    tool = Ragents::Tool.new(:tag) do
      parameter :tags, type: :array, default: default_tags
      execute { |tags:| (tags << "x").size }
    end

    refute_predicate default_tags, :frozen?
    assert_predicate tool, :ractor_safe?
    # On main the default object is shared across calls, as before.
    assert_equal [ 2, 3 ], [ tool.call, tool.call ]
    # The Ractor copy hands each call its own copy of the frozen default.
    assert_equal [ 2, 2 ], [ tool.ractor_copy.call, tool.ractor_copy.call ]
    assert_equal 2, Ractor.new(tool.ractor_copy) { |t| t.call }.value
  end

  def test_tools_that_keep_state_in_ivars_work_on_main_and_stay_out_of_ractors
    agent_class = Class.new(Ragents::Agent) do
      tool :lookup do
        description "Memoized lookup"
        parameter :key, type: :string, required: true
        execute { |key:| (@cache ||= {})[key] ||= key.upcase }
      end

      tool :client do
        @client = Struct.new(:lock).new(Mutex.new)
        description "Uses a client object"
        execute { @client.class.name.to_s }
      end
    end

    assert_equal "A", agent_class.defined_tools[:lookup].call(key: "a")
    refute_predicate agent_class, :ractor_safe?
    reasons = agent_class.ractor_unsafe_reasons.join("\n")
    assert_match(/tool :lookup execute block assigns @cache/, reasons)
    assert_match(/tool :client keeps mutable state in @client/, reasons)
  end

  def test_tool_with_shareable_ivars_runs_in_a_ractor
    agent_class = Class.new(Ragents::Agent) do
      tool :prefixed do
        @prefix = "pre"
        description "Prefix the text"
        parameter :text, type: :string, required: true
        execute { |text:| "#{@prefix}-#{text}" }
      end
    end
    @provider.stub_tool_call(name: :prefixed, arguments: { text: "x" })
    @provider.stub_response(content: "done")

    context = agent_class.run_in_ractor(provider: @provider, input: "go")
    assert_equal "pre-x", context.messages.find(&:tool?).content
  end

  def test_subclass_prompt_is_judged_on_its_own
    seen = []
    parent = Class.new(Ragents::Agent) { system_prompt { "parent #{seen.size}" } }
    child = Class.new(parent) { system_prompt "child prompt" }
    @provider.stub_response(content: "ok")

    refute_predicate parent, :ractor_safe?
    assert_predicate child, :ractor_safe?
    assert_equal "child prompt", child.run_in_ractor(provider: @provider, input: "go").system_message.content
  end

  def test_tool_capturing_mutable_state_stays_on_main_and_explains_why
    calls = []
    agent_class = Class.new(Ragents::Agent) do
      tool :record do
        description "Remember the text"
        parameter :text, type: :string, required: true
        execute { |text:| (calls << text).size.to_s }
      end
    end

    refute_predicate agent_class, :ractor_safe?
    assert_match(/tool :record execute block can't be shared/, agent_class.ractor_unsafe_reasons.join)

    error = assert_raises(Ragents::RactorSafetyError) { agent_class.run_async(provider: @provider) }
    assert_match(/can't run inside a Ractor/, error.message)

    @provider.stub_tool_call(name: :record, arguments: { text: "kept" })
    @provider.stub_response(content: "ok")
    agent_class.new(provider: @provider).run(input: "go")
    assert_equal [ "kept" ], calls
  end

  def test_requires_main_thread_keeps_an_agent_out_of_ractors
    agent_class = Class.new(Ragents::Agent) do
      tool :db do
        description "Touch the database"
        requires_main_thread!
        execute { "rows" }
      end
    end

    refute_predicate agent_class, :ractor_safe?
    assert_match(/requires_main_thread!/, agent_class.ractor_unsafe_reasons.join)
  end

  def test_prompt_lambda_writing_outer_state_still_works_on_main
    counter = 0
    agent_class = Class.new(Ragents::Agent) { system_prompt -> { "Prompt #{counter += 1}" } }

    refute_predicate agent_class, :ractor_safe?
    assert_equal "Prompt 1", agent_class.new(provider: @provider).context.system_message.content
  end

  def test_provider_that_cannot_enter_a_ractor_raises_a_clear_error
    provider = Ragents::Providers::Test.new
    provider.instance_variable_set(:@queue, Thread::Queue.new)

    error = assert_raises(Ragents::RactorSafetyError) { EchoAgent.run_async(provider: provider) }
    assert_match(/Test\) and options must be shareable or copyable/, error.message)
  end

  def test_orchestrator_parallel_runs_real_agents_in_ractors
    @provider.stub_tool_call(name: :echo, arguments: { text: "x" })
    @provider.stub_response(content: "done")

    orchestrator = Ragents::Orchestrator.new(provider: @provider)
    orchestrator.register(:echo, EchoAgent)
    results = orchestrator.parallel([ :echo, { input: "a" } ], [ :echo, { input: "b" } ])

    # The Test provider is copied into each Ractor, so each run sees all stubs.
    assert_equal [ "done", "done" ], results.map { |c| c.last_message.content }
    assert_equal [ "echo:x", "echo:x" ], results.map { |c| c.messages[3].content }
  end

  def setup
    @provider = build_test_provider
  end
end
