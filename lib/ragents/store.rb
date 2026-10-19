# frozen_string_literal: true

module Ragents
  # Shared mutable state for agents running in different Ractors.
  #
  # Ractors share only immutable values. Most agent state already fits: agent
  # definitions are shareable, and a conversation is a frozen Context that is
  # passed in and handed back. State that many agents *write* — facts they
  # learn, counters, a scratchpad — can't be shared directly, so a Store keeps
  # it inside one Ractor of its own and everyone else sends that Ractor
  # requests. The Store object is itself shareable: hand it to a worker and
  # call it from there.
  #
  #   memory = Ragents::Store.new
  #   memory.append(:facts, "The user prefers Ruby")
  #   Ractor.new(memory) { |m| m.get(:facts) }.value   # => ["The user prefers Ruby"]
  #   memory.update(:visits) { |n| (n || 0) + 1 }      # atomic read-modify-write
  #
  # Values are copied in and out (pass Ractor.make_shareable(value) to share a
  # large immutable value instead). Requests are served one at a time, which
  # is what makes #update atomic.
  #
  # Like any Ractor::Port#receive on Ruby 4.0, a request blocks its thread even
  # inside a non-blocking Fiber; from a Fiber-scheduled server, make requests
  # from a worker (e.g. inside a Ragents::Pool job) or a separate thread.
  class Store
    OPERATIONS = %i[get put fetch append delete update keys to_h clear].freeze

    def initialize(initial = {}, name: "ragents-store")
      boot = Ractor::Port.new
      @ractor = Ractor.new(boot, initial, name: name) do |boot_port, data|
        inbox = Ractor::Port.new
        boot_port << inbox
        while (request = inbox.receive) != :stop
          op, key, value, reply = request
          begin
            result =
              case op
              when :get then data[key]
              when :put then data[key] = value
              when :fetch then data.fetch(key, value)
              when :append
                list = (data[key] ||= [])
                list << value
                list.size
              when :delete then data.delete(key)
              when :update then data[key] = value.call(data[key])
              when :keys then data.keys
              when :to_h then data
              when :clear
                data.clear
                nil
              end
            reply << [:ok, result]
          rescue Exception => e # rubocop:disable Lint/RescueException -- keep the store alive and report to the caller
            reply << [:error, "#{e.class}: #{e.message}"]
          end
        end
        :stopped
      end
      @port = boot.receive
      Ractor.make_shareable(self)
    end

    def get(key) = request(:get, key)
    def [](key) = get(key)
    def put(key, value) = request(:put, key, value)
    def []=(key, value)
      put(key, value)
    end
    def fetch(key, default = nil) = request(:fetch, key, default)

    # Appends to the array at key (creating it); returns the new size.
    def append(key, value) = request(:append, key, value)
    def delete(key) = request(:delete, key)
    def keys = request(:keys)
    def to_h = request(:to_h)
    def clear = request(:clear)

    # Atomically replaces the value at key with the block's result. The block
    # runs inside the store's Ractor (it is made shareable with
    # Ractor.shareable_proc), so it may only capture outer variables that hold
    # shareable values and are never reassigned.
    def update(key, &block)
      raise ArgumentError, "update needs a block" unless block

      request(:update, key, Ractor.shareable_proc(self: nil, &block))
    end

    def stop
      @port << :stop
      @ractor.join
      nil
    rescue Ractor::ClosedError
      nil
    end

    private

    def request(op, key = nil, value = nil)
      reply = Ractor::Port.new
      @port << [op, key, value, reply]
      status, result = reply.receive
      raise Error, result if status == :error

      result
    ensure
      reply&.close
    end
  end
end
