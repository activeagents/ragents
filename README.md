# Ragents

A pure Ruby, Ractor-based AI agent framework for concurrent, isolated agent execution.

Ragents provides a clean DSL for defining AI agents with tools, uses [RubyLLM](https://rubyllm.com/) for access to 500+ models across all major providers, and enables true parallel execution using Ruby's Ractor primitive.

## Features

- **Ractor-First Concurrency**: Agents run in isolated Ractors for true parallelism
- **Pure Ruby**: No Rails dependencies (optional Rails integration available)
- **Message-Passing Architecture**: Immutable messages and contexts for safe concurrency
- **Tool-Based Actions**: Declarative tool definitions with JSON Schema support
- **500+ Models**: Uses RubyLLM for OpenAI, Anthropic, Gemini, Ollama, and more
- **Multi-Agent Orchestration**: Sequential workflows, parallel execution, and supervision
- **Composable**: Agents can coordinate with other agents for complex workflows

## Installation

Add to your Gemfile:

```ruby
gem "ragents"
```

Then run:

```bash
bundle install
```

## Quick Start

### Configure RubyLLM

First, configure RubyLLM with your API keys:

```ruby
# config/initializers/ruby_llm.rb (Rails)
# or at application startup

RubyLLM.configure do |config|
  config.openai_api_key = ENV["OPENAI_API_KEY"]
  config.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]
  # Add other providers as needed
end
```

### Define an Agent

```ruby
class ResearchAgent < Ragents::Agent
  system_prompt "You are a research assistant. Use tools to find information."

  tool :search_web do
    description "Search the web for information"
    parameter :query, type: :string, required: true, description: "Search query"
    parameter :limit, type: :integer, default: 5

    execute do |query:, limit:|
      SearchService.search(query, limit: limit)
    end
  end

  tool :summarize do
    description "Summarize a piece of text"
    parameter :text, type: :string, required: true

    execute do |text:|
      text.split.first(50).join(" ") + "..."
    end
  end
end
```

### Run the Agent

```ruby
# Create a provider with any RubyLLM-supported model
provider = Ragents::Providers::RubyLLM.new(model: "gpt-4o")
# Or: "claude-sonnet-4-20250514", "gemini-2.0-flash", "llama3.2", etc.

# Create and run the agent
agent = ResearchAgent.new(provider: provider)
result = agent.run(input: "Research the latest developments in Ruby 3.4")

puts result.last_message.content
```

## Core Concepts

### Messages

Immutable, Ractor-shareable message objects:

```ruby
user_msg = Ragents::Message.user("Hello!")
assistant_msg = Ragents::Message.assistant("Hi there!")
system_msg = Ragents::Message.system("You are helpful.")
tool_result = Ragents::Message.tool("result data", tool_call_id: "call_123")

# Messages are frozen for Ractor safety
user_msg.frozen? # => true
```

### Context

Immutable conversation state:

```ruby
context = Ragents::Context.new
context = context.add_message(Ragents::Message.user("Hello"))
context = context.add_message(Ragents::Message.assistant("Hi!"))

# Contexts are immutable - operations return new contexts
context.size # => 2
context.last_message.content # => "Hi!"

# Truncate long conversations
short_context = context.truncate(max_messages: 10, keep_system: true)

# Fork for branching conversations
branch = context.fork(experiment: "new-prompt")
```

### Tools

Declarative tool definitions:

```ruby
tool = Ragents::Tool.new(:calculate) do
  description "Perform a calculation"

  parameter :expression, type: :string, required: true
  parameter :precision, type: :integer, default: 2

  execute do |expression:, precision:|
    result = eval(expression) # Be careful with eval in production!
    result.round(precision)
  end
end

# Tools generate JSON Schema for LLM function calling
tool.to_json_schema
# => { type: "function", function: { name: "calculate", ... } }
```

### Provider (RubyLLM)

Access 500+ models through RubyLLM:

```ruby
# OpenAI models
provider = Ragents::Providers::RubyLLM.new(model: "gpt-4o")
provider = Ragents::Providers::RubyLLM.new(model: "gpt-4o-mini")

# Anthropic Claude
provider = Ragents::Providers::RubyLLM.new(model: "claude-sonnet-4-20250514")
provider = Ragents::Providers::RubyLLM.new(model: "claude-3-5-haiku-latest")

# Google Gemini
provider = Ragents::Providers::RubyLLM.new(model: "gemini-2.0-flash")

# Local Ollama
provider = Ragents::Providers::RubyLLM.new(model: "llama3.2")

# Test provider for unit tests
test = Ragents::Providers::Test.new
test.stub_response(content: "Mocked response")
```

## Multi-Agent Orchestration

### Orchestrator

Coordinate multiple agents:

```ruby
orchestrator = Ragents::Orchestrator.new(provider: provider)

# Register agents
orchestrator.register(:researcher, ResearchAgent)
orchestrator.register(:writer, WriterAgent)
orchestrator.register(:editor, EditorAgent)

# Run a single agent
result = orchestrator.run(:researcher, input: "Research topic X")

# Run agents in parallel (uses Ractors)
results = orchestrator.parallel(
  [:researcher, { input: "Topic A" }],
  [:researcher, { input: "Topic B" }],
  [:researcher, { input: "Topic C" }]
)

# Sequential workflow
final = orchestrator.workflow do |w|
  w.step(:researcher, input: "Research the topic")
  w.step(:writer) { |ctx| { input: "Write about: #{ctx.last_response}" } }
  w.step(:editor)
end

# Supervised execution with automatic restarts
result = orchestrator.supervised(:researcher,
  input: "Important task",
  max_restarts: 3,
  restart_delay: 1
)
```

### Ractor-Based Parallelism

Run agents in isolated Ractors:

```ruby
# Async execution
ractor = ResearchAgent.run_async(
  provider: provider,
  input: "Research task"
)

# Do other work while agent runs...

# Get result when ready
result = ractor.take

# Or use the synchronous helper
result = ResearchAgent.run_in_ractor(
  provider: provider,
  input: "Research task"
)
```

## Configuration

### Global Configuration

```ruby
Ragents.configure do |config|
  config.max_iterations = 10  # Max tool call loops per run
  config.timeout = 120        # Request timeout in seconds
  config.default_model = "gpt-4o"
end
```

### Rails Integration

When Rails is detected, Ragents automatically:
- Adds `app/agents` to autoload paths
- Provides configuration via `config.ragents`
- Instruments agent runs with `ActiveSupport::Notifications`

```ruby
# config/initializers/ragents.rb
Rails.application.config.ragents.max_iterations = 15
Rails.application.config.ragents.timeout = 180
```

## Testing

Use the test provider for unit tests:

```ruby
class MyAgentTest < Minitest::Test
  def setup
    @provider = Ragents::Providers::Test.new
  end

  def test_agent_responds
    @provider.stub_response(content: "Hello!")

    agent = MyAgent.new(provider: @provider)
    result = agent.run(input: "Hi")

    assert_equal "Hello!", result.last_message.content
  end

  def test_agent_uses_tool
    @provider.stub_tool_call(name: :search, arguments: { query: "test" })
    @provider.stub_response(content: "Found results")

    agent = MyAgent.new(provider: @provider)
    result = agent.run(input: "Search for test")

    # Verify requests were made
    assert_equal 2, @provider.request_count
  end
end
```

## Comparison with Active Agent

| Feature | Ragents | Active Agent |
|---------|---------|--------------|
| Framework | Pure Ruby | Rails-dependent |
| Concurrency | Ractor-based | Thread/Fiber |
| Messages | Immutable | Mutable |
| Focus | Multi-agent orchestration | Rails integration |
| LLM Backend | RubyLLM (500+ models) | Multiple adapters |

Ragents is designed to complement Active Agent - use Ragents for complex multi-agent workflows and integrate results back into Active Agent actions.

## Requirements

- Ruby >= 3.2.0 (Ractors available in 3.x, optimized for 3.3+)
- ruby_llm gem (automatically installed)

## Contributing

Bug reports and pull requests are welcome on GitHub.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
