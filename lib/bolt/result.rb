# frozen_string_literal: true

require 'json'
require 'bolt/error'

module Bolt
  class Result
    attr_reader :target, :value, :action, :object

    def self.from_exception(target, exception, action: 'action')
      if exception.is_a?(Bolt::Error)
        error = exception.to_h
      else
        error = {
          'kind' => 'puppetlabs.tasks/exception-error',
          'issue_code' => 'EXCEPTION',
          'msg' => exception.message,
          'details' => { 'class' => exception.class.to_s }
        }
        error['details']['stack_trace'] = exception.backtrace.join('\n') if exception.backtrace
      end
      Result.new(target, error: error, action: action)
    end

    def self.for_command(target, stdout, stderr, exit_code, action, command)
      value = {
        'stdout' => stdout,
        'stderr' => stderr,
        'exit_code' => exit_code
      }
      unless exit_code == 0
        value['_error'] = {
          'kind' => 'puppetlabs.tasks/command-error',
          'issue_code' => 'COMMAND_ERROR',
          'msg' => "The command failed with exit code #{exit_code}",
          'details' => { 'exit_code' => exit_code }
        }
      end
      new(target, value: value, action: action, object: command)
    end

    def self.for_task(target, stdout, stderr, exit_code, task)
      stdout.force_encoding('utf-8') unless stdout.encoding == Encoding::UTF_8
      value = if stdout.valid_encoding?
                parse_hash(stdout) || { '_output' => stdout }
              else
                { '_error' => { 'kind' => 'puppetlabs.tasks/task-error',
                                'issue_code' => 'TASK_ERROR',
                                'msg' => 'The task result contained invalid UTF-8 on stdout',
                                'details' => {} } }
              end

      if exit_code != 0 && value['_error'].nil?
        msg = if stdout.empty?
                if stderr.empty?
                  "The task failed with exit code #{exit_code} and no output"
                else
                  "The task failed with exit code #{exit_code} and no stdout, but stderr contained:\n#{stderr}"
                end
              else
                "The task failed with exit code #{exit_code}"
              end
        value['_error'] = { 'kind' => 'puppetlabs.tasks/task-error',
                            'issue_code' => 'TASK_ERROR',
                            'msg' => msg,
                            'details' => { 'exit_code' => exit_code } }
      end
      new(target, value: value, action: 'task', object: task)
    end

    def self.parse_hash(string)
      value = JSON.parse(string)
      value if value.is_a? Hash
    rescue JSON::ParserError
      nil
    end

    def self.for_upload(target, source, destination)
      new(target, message: "Uploaded '#{source}' to '#{target.host}:#{destination}'", action: 'upload', object: source)
    end

    # Satisfies the Puppet datatypes API
    def self.from_asserted_args(target, value)
      new(target, value: value)
    end

    def self._pcore_init_from_hash
      raise "Result shouldn't be instantiated from a pcore_init class method. How did this get called?"
    end

    def _pcore_init_from_hash(init_hash)
      opts = init_hash.reject { |k, _v| k == 'target' }
      initialize(init_hash['target'], opts.transform_keys(&:to_sym))
    end

    def _pcore_init_hash
      { 'target' => @target,
        'error' => @value['_error'],
        'message' => @value['_output'],
        'value' => @value,
        'action' => @action,
        'object' => @object }
    end

    def initialize(target, error: nil, message: nil, value: nil, action: 'action', object: nil)
      @target = target
      @value = value || {}
      @action = action
      @object = object
      if error && !error.is_a?(Hash)
        raise "TODO: how did we get a string error"
      end
      @value['_error'] = error if error
      @value['_output'] = message if message
    end

    def message
      @value['_output']
    end

    def message?
      message && !message.strip.empty?
    end

    def status_hash
      {
        target: @target.name,
        action: action,
        object: object,
        status: status,
        value: @value
      }
    end

    def generic_value
      value.reject { |k, _| %w[_error _output].include? k }
    end

    def eql?(other)
      self.class == other.class &&
        target == other.target &&
        value == other.value
    end

    def [](key)
      value[key]
    end

    def ==(other)
      eql?(other)
    end

    def to_json(opts = nil)
      status_hash.to_json(opts)
    end

    def to_s
      to_json
    end

    def to_data
      Bolt::Util.walk_keys(status_hash, &:to_s)
    end

    def status
      ok? ? 'success' : 'failure'
    end

    def ok?
      error_hash.nil?
    end
    alias ok ok?
    alias success? ok?

    # This allows access to errors outside puppet compilation
    # it should be prefered over error in bolt code
    def error_hash
      value['_error']
    end

    # Warning: This will fail outside of a compilation.
    # Use error_hash inside bolt.
    # Is it crazy for this to behave differently outside a compiler?
    def error
      if error_hash
        Puppet::DataTypes::Error.from_asserted_hash(error_hash)

      end
    end
  end
end
