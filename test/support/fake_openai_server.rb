# frozen_string_literal: true

require "json"
require "socket"

# A tiny OpenAI-compatible Chat Completions server for tests (stdlib only), so
# the provider can be exercised end to end, including from inside Ractors
# where WebMock's global stubs can't reach.
#
# Behaviour, from the request body:
# - model "status-NNN"  -> that HTTP status with an error body
# - stream: true        -> SSE: one chunk per word of the last user message,
#                          then a usage chunk and [DONE]
# - tools offered and no tool result yet -> a call to the first tool with
#                          {"text": <last user message>}
# - otherwise           -> "echo: <last user message>"
class FakeOpenAIServer
  attr_reader :port, :connections, :requests

  # close_after_response: close each connection after one response without
  # saying so, to exercise stale keep-alive handling.
  # sse_newline: line ending for SSE events ("\n" or "\r\n"); CRLF events are
  # split across chunks to exercise buffering.
  def initialize(close_after_response: false, sse_newline: "\n")
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @close_after_response = close_after_response
    @sse_newline = sse_newline
    @connections = 0
    @requests = Thread::Queue.new
    @thread = Thread.new { accept_loop }
  end

  def base_url = "http://127.0.0.1:#{@port}/v1"

  def received
    list = []
    list << @requests.pop until @requests.empty?
    list
  end

  def stop
    @thread.kill
    @server.close
  end

  private

  def accept_loop
    loop do
      socket = @server.accept
      @connections += 1
      Thread.new(socket) { |s| serve(s) }
    end
  rescue IOError
    nil
  end

  def serve(socket)
    loop do
      request_line = socket.gets or break
      headers = {}
      while (line = socket.gets) && line != "\r\n"
        name, value = line.split(":", 2)
        headers[name.strip.downcase] = value.to_s.strip
      end
      body = JSON.parse(socket.read(Integer(headers.fetch("content-length", "0"))))
      @requests << { path: request_line.split[1], headers: headers, body: body }
      respond(socket, body)
      break if @close_after_response
    end
  rescue IOError, Errno::ECONNRESET, Errno::EPIPE
    nil
  ensure
    socket.close
  end

  def respond(socket, body)
    model = body["model"].to_s
    last_user = Array(body["messages"]).reverse.find { |m| m["role"] == "user" }&.dig("content").to_s

    if (status = model[/\Astatus-(\d+)\z/, 1])
      json(socket, Integer(status), { error: { message: "fake #{status}" } })
    elsif body["stream"]
      stream(socket, model, last_user)
    elsif (tool = Array(body["tools"]).first) && Array(body["messages"]).none? { |m| m["role"] == "tool" }
      json(socket, 200, completion(model, { role: "assistant", content: nil, tool_calls: [ {
        id: "call_1", type: "function",
        function: { name: tool.dig("function", "name"), arguments: JSON.generate(text: last_user) }
      } ] }, "tool_calls"))
    else
      json(socket, 200, completion(model, { role: "assistant", content: "echo: #{last_user}" }, "stop"))
    end
  end

  def completion(model, message, finish_reason)
    { id: "chatcmpl-fake", object: "chat.completion", model: model,
      choices: [ { index: 0, message: message, finish_reason: finish_reason } ],
      usage: { prompt_tokens: 3, completion_tokens: 2, total_tokens: 5 } }
  end

  def json(socket, status, payload)
    data = JSON.generate(payload)
    socket.write "HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\nContent-Length: #{data.bytesize}\r\n\r\n#{data}"
  end

  def stream(socket, model, text)
    socket.write "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n"
    events = text.split.map { |word| { model: model, choices: [ { index: 0, delta: { content: "#{word} " } } ] } }
    events << { model: model, choices: [ { index: 0, delta: {}, finish_reason: "stop" } ] }
    events << { model: model, choices: [], usage: { prompt_tokens: 3, completion_tokens: events.size - 1 } }
    nl = @sse_newline
    payloads = events.map { |e| "data: #{JSON.generate(e)}#{nl}#{nl}" } << "data: [DONE]#{nl}#{nl}"
    if nl == "\n"
      payloads.each { |p| chunk(socket, p) }
    else
      # Split mid-terminator ("...\r" | "\n\r\n") so the client must buffer.
      payloads.join.scan(/.{1,7}/m).each { |piece| chunk(socket, piece) }
    end
    socket.write "0\r\n\r\n"
  end

  def chunk(socket, data)
    socket.write "#{data.bytesize.to_s(16)}\r\n#{data}\r\n"
  end
end
