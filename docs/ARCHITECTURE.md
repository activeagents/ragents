# Ragents Architecture

## Overview

Ragents is a pure Ruby, Ractor-based AI agent framework designed for concurrent, isolated agent execution. It uses RubyLLM as the LLM backend, providing access to 500+ models across all major providers.

## Core Design Principles

1. **Ractor-First Concurrency**: Agents run in isolated Ractors for true parallelism and memory safety
2. **Pure Ruby**: No Rails dependencies in core; optional adapters for framework integration
3. **Message-Passing Architecture**: Agents exchange immutable messages and contexts through Ractor ports
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

## Agents in Ractors (Ruby 4.0)

### Three kinds of agent state

Ractors share only immutable values, and a non-main Ractor may only read a
class instance variable whose value is shareable. Agent state splits cleanly
along that line:

| State | Where it lives | How it crosses Ractors |
|---|---|---|
| Definitions: system prompt, tool schemas, execute blocks | Class instance variables | A frozen, shareable copy is made when the class is defined; other Ractors read the copies (`ractor_system_prompt`, `ractor_tools`) |
| Conversation | `Ragents::Context` (frozen) | Passed in, handed back; a new turn is a new Context |
| Shared mutable memory: facts, counters, scratchpads | `Ragents::Store`, owned by its own Ractor | Requests over a `Ractor::Port`; the Store object is shareable |

The definitions themselves are left exactly as defined, so agents behave the
same on the main Ractor (tools can keep a cache, providers that call
`tool.executor` directly see the tool as `self`). The copies for other Ractors:
a frozen copy of a prompt string; a `Ractor.shareable_proc` copy of a prompt
block that keeps its `self`; and for each tool, a frozen `Tool#ractor_copy`
whose execute block is shared with `self: nil` and run with `instance_exec` on
the copy, with its own copies of parameter defaults per call.

A definition gets no copy when its block writes or captures mutable outer
state, when a tool's execute block assigns instance variables (found from its
bytecode; the copy is frozen), or when a tool's definition left mutable state
in instance variables. That agent still runs on the main Ractor;
`Agent.ractor_safe?` is false, and `run_async`/`Pool#submit` raise
`Ragents::RactorSafetyError` listing why. Tools are inherited, so an unsafe
parent tool keeps subclasses out too; system prompts aren't, so only the
class's own prompt counts.

### Running agents

- `Agent.run_async` / `run_in_ractor`: one Ractor per run, result read with
  `Ractor#value`. Fine for one-off fan-out.
- `Ragents::Pool`: long-lived worker Ractors fed through `Ractor::Port`s. One
  dispatcher thread hands jobs to free worker slots; one collector thread
  receives replies and passes each to its job's `Thread::Queue`. Callers only
  ever wait on that queue, which yields to a Fiber scheduler. On Ruby 4.0,
  `Ractor::Port#receive` blocks its whole thread even inside a non-blocking
  Fiber (ruby/ruby#18819 proposes changing that), so waiting on a port directly
  from a Falcon/Async request would stall every other request on the reactor.
- `Orchestrator#parallel` uses a pool when given one.

### Providers

A provider is sent into each Ractor with the run. `Providers::OpenAICompatible`
is frozen and shareable, so it is passed by reference, and it keeps its
keep-alive connections in Ractor-local storage. `Providers::Test` is copied.
`Providers::RubyLLM` keeps configuration in module state (`RubyLLM.config`),
which non-main Ractors can't read, so it is main-Ractor only.

### Garbage collection

Ruby 4.0 still collects garbage with a VM-wide stop-the-world GC. Allocation
in any Ractor pauses all of them, so allocation-heavy tool work scales less
than CPU-only work.

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
- Errors inside a Ractor surface as `Ractor::RemoteError` (run_async) or
  `Ragents::Pool::RemoteError` with the original exception as `cause`
- Automatic restart with configurable max retries

## Future Considerations

1. **Persistent Context**: Store conversation history in databases
2. **Streaming**: Real-time token streaming from providers
3. **Memory/RAG**: Vector store integration for long-term memory
4. **Observability**: Instrumentation and tracing hooks
