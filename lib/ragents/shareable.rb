# frozen_string_literal: true

module Ragents
  # Raised when an agent is asked to run in a Ractor but part of its
  # definition can't be shared with one.
  class RactorSafetyError < Error; end

  # Helpers for turning agent definitions into Ractor-shareable values.
  #
  # A non-main Ractor may only read a class instance variable whose value is
  # shareable (Ruby 4.0 raises Ractor::IsolationError otherwise), and agent
  # definitions live in class instance variables. So every DSL value is made
  # shareable when it is defined, without changing how it behaves on the main
  # Ractor:
  #
  # - strings and other data become frozen copies (the caller's object is left
  #   alone);
  # - blocks become Ractor.shareable_proc copies that keep their original self
  #   when that self is shareable (an agent class is). A block whose self is
  #   the object it belongs to (a tool's execute block) is shared with
  #   self: nil and re-bound with instance_exec when called.
  #
  # A block that writes, or may see reassigned, outer variables, or that
  # captures mutable objects, can't be shared. Those definitions keep working
  # on the main Ractor and report a reason instead.
  module Shareable
    module_function

    # @return [Array(Object, String, nil)] the shareable value (or the original
    #   when it can't be shared) and the reason it can't, if any
    def value(object)
      return [object, nil] if Ractor.shareable?(object)

      [Ractor.make_shareable(deep_dup(object)), nil]
    rescue Ractor::Error, TypeError, ArgumentError => e
      [object, e.message]
    end

    # @param owner [Object, nil] the object the block is defined on; when the
    #   block's self is the owner it is shared with self: nil and must be
    #   called with instance_exec on the owner
    # @return [Array(Proc, Symbol, String, nil)] the proc, how to call it
    #   (:call or :instance_exec), and the reason it can't be shared, if any
    def block(callable, owner: nil)
      return [callable, :call, nil] if Ractor.shareable?(callable)

      receiver = begin
        callable.binding.receiver
      rescue ArgumentError
        return [callable, :call, "it has no inspectable binding (a method or C-level proc)"]
      end

      if !owner.nil? && receiver.equal?(owner)
        [Ractor.shareable_proc(self: nil, &callable), :instance_exec, nil]
      elsif Ractor.shareable?(receiver)
        [Ractor.shareable_proc(self: receiver, &callable), :call, nil]
      else
        [callable, :call, "its self (#{receiver.class}) is not shareable"]
      end
    rescue Ractor::Error, ArgumentError => e
      [callable, :call, e.message]
    end

    def deep_dup(object)
      case object
      when Hash then object.to_h { |k, v| [deep_dup(k), deep_dup(v)] }
      when Array then object.map { |v| deep_dup(v) }
      when String then object.frozen? ? object : object.dup
      else object
      end
    end
  end
end
