# Ragents Architecture

## Overview

Ragents is a pure Ruby, Ractor-based AI agent framework designed for concurrent, isolated agent execution. It uses RubyLLM as the LLM backend, providing access to 500+ models across all major providers.

## Core Design Principles

1. **Ractor-First Concurrency**: Agents run in isolated Ractors for true parallelism and memory safety
2. **Pure Ruby**: No Rails dependencies in core; optional adapters for framework integration
3. **Message-Passing Architecture**: Agents communicate via immutable messages through Ractor pipes
4. **Tool-Based Actions**: Agents interact with the world through declarative tool definitions
5. **RubyLLM Backend**: Single provider interface leveraging RubyLLM for 500+ models
6. **Composable**: Agents can orchestrate other agents for complex workflows

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                         Orchestrator                            │
│  (coordinates multiple agents, manages workflows, supervision)  │
└─────────────────────────────────────────────────────────────────┘
                                │
                ┌───────────────┼───────────────┐
                ▼               ▼               ▼
        ┌─────────────┐ ┌─────────────┐ ┌─────────────┐
        │   Ractor    │ │   Ractor    │ │   Ractor    │
        │  ┌───────┐  │ │  ┌───────┐  │ │  ┌───────┐  │
        │  │ Agent │  │ │  │ Agent │  │ │  │ Agent │  │
        │  └───────┘  │ │  └───────┘  │ │  └───────┘  │
        │      │      │ │      │      │ │      │      │
        │  ┌───────┐  │ │  ┌───────┐  │ │  ┌───────┐  │
        │  │Context│  │ │  │Context│  │ │  │Context│  │
        │  └───────┘  │ │  └───────┘  │ │  └───────┘  │
        │      │      │ │      │      │ │      │      │
        │  ┌───────┐  │ │  ┌───────┐  │ │  ┌───────┐  │
        │  │ Tools │  │ │  │ Tools │  │ │  │ Tools │  │
        │  └───────┘  │ │  └───────┘  │ │  └───────┘  │
        └─────────────┘ └─────────────┘ └─────────────┘
                │               │               │
                └───────────────┼───────────────┘
                                ▼
                    ┌─────────────────────┐
                    │  RubyLLM Provider   │
                    │   (500+ models)     │
                    └─────────────────────┘
```

## Core Components

### 1. Agent (`Ragents::Agent`)

The fundamental unit of work. An Agent:
- Runs inside a Ractor for isolation
- Has a system prompt defining its behavior
- Has access to a set of Tools
- Maintains a Context (conversation history)
- Communicates via message passing

```ruby
class ResearchAgent < Ragents::Agent
  system_prompt "You are a research assistant..."

  tool :search_web do |query:|
    # Tool implementation
  end

  tool :summarize do |text:|
    # Tool implementation
  end
end
```

### 2. Tool (`Ragents::Tool`)

A callable action that an Agent can invoke:
- Declarative definition with name, description, parameters
- JSON Schema for parameter validation
- Converted to RubyLLM::Tool format for LLM calls

```ruby
Ragents::Tool.new(:search_web) do
  description "Search the web for information"

  parameter :query, type: :string, required: true
  parameter :limit, type: :integer, default: 10

  execute do |query:, limit:|
    # Implementation
  end
end
```

### 3. Context (`Ragents::Context`)

Immutable conversation state:
- Message history (user, assistant, tool calls/results)
- Metadata and configuration
- Passed between Ractors as frozen/shareable objects

```ruby
context = Ragents::Context.new
context = context.add_message(role: :user, content: "Hello")
context = context.add_message(role: :assistant, content: "Hi there!")
```

### 4. Message (`Ragents::Message`)

Immutable message value object:
- Role (system, user, assistant, tool)
- Content (text, tool calls, tool results)
- Frozen for Ractor safety

### 5. Provider (`Ragents::Providers::RubyLLM`)

RubyLLM-based provider for all LLM interactions:
- Single interface for 500+ models
- OpenAI, Anthropic, Gemini, Ollama, and more
- Handles tool call parsing and response formatting

```ruby
Ragents::Providers::RubyLLM.new(model: "gpt-4o")
Ragents::Providers::RubyLLM.new(model: "claude-sonnet-4-20250514")
Ragents::Providers::RubyLLM.new(model: "gemini-2.0-flash")
```

### 6. Orchestrator (`Ragents::Orchestrator`)

Coordinates multiple agents:
- Supervisor patterns (automatic restart on failure)
- Agent routing and hand-offs
- Workflow composition (sequential, parallel, conditional)
- Ractor-based parallel execution

```ruby
orchestrator = Ragents::Orchestrator.new(provider: provider)

orchestrator.register(:researcher, ResearchAgent)
orchestrator.register(:writer, WriterAgent)

# Parallel execution in Ractors
results = orchestrator.parallel(
  [:researcher, { input: "Topic A" }],
  [:researcher, { input: "Topic B" }]
)
```

## Ruby 4.0 Ractor Features

Ragents requires Ruby 4.0+ to leverage critical Ractor improvements:

### Local Garbage Collection
- Each Ractor has its own GC, reducing stop-the-world pauses
- Better memory isolation between agents
- Improved performance for long-running agent workflows

### Shareable Objects
These must be Ractor-shareable (frozen or specially marked):
- Tool definitions
- System prompts
- Configuration
- Messages and Context (frozen)

### Message Passing
Agents communicate via Ractor pipes:
```ruby
# Orchestrator sends to agent
agent_ractor.send([:run, context])

# Agent responds
result = agent_ractor.take
```

## Integration Points

### Active Agent Integration

```ruby
# In an Active Agent action
class MyAgent < ActiveAgent::Base
  def research
    ragent = Ragents::Agent.run(ResearchAgent, context: current_context)
    render_generation ragent.result
  end
end
```

### Rails Integration (Optional)

```ruby
# config/initializers/ragents.rb
Rails.application.config.ragents.max_iterations = 15
Rails.application.config.ragents.timeout = 180
```

## Error Handling

- Agents can fail; Orchestrator handles supervision
- Ractor exceptions are captured and re-raised safely
- Automatic restart with configurable max retries

## Future Considerations

1. **Persistent Context**: Store conversation history in databases
2. **Streaming**: Real-time token streaming from providers
3. **Memory/RAG**: Vector store integration for long-term memory
4. **Observability**: Instrumentation and tracing hooks
