# frozen_string_literal: true

require 'tty-command'

class PrettyOnFailure < TTY::Command::Printers::Abstract
  TIME_FORMAT = '%5.3f %s'

  def initialize(*)
    super
    @uuid = options.fetch(:uuid, true)
    @cached = []
  end

  def print_command_start(cmd, *args)
    message = ["Running #{decorate(cmd.to_command, :yellow, :bold)}"]
    message << args.map(&:chomp).join(' ') unless args.empty?
    write(cmd, message.join, @cached)
  end

  def print_command_out_data(cmd, *args)
    message = args.map(&:chomp).join(' ')
    write(cmd, "\t#{message}", out_data)
  end

  def print_command_err_data(cmd, *args)
    message = args.map(&:chomp).join(' ')
    write(cmd, "\t#{decorate(message, :red)}", err_data)
  end

  def print_command_exit(cmd, status, runtime, *_args)
    unless status.zero?
      output << @cached.join
      output << out_data
      output << err_data

      runtime = format(TIME_FORMAT, runtime, pluralize(runtime, 'second'))
      message = ["Finished in #{runtime}"]
      message << " with exit status #{status}" if status
      message << " (#{success_or_failure(status)})"
      write(cmd, message.join)
    end
    @cached.clear
  end

  # Write message out to output
  #
  # @api private
  def write(cmd, message, data = nil)
    cmd_set_uuid = cmd.options.fetch(:uuid, true)
    uuid_needed = cmd.options[:uuid].nil? ? @uuid : cmd_set_uuid
    out = []
    out << "[#{decorate(cmd.uuid, :green)}] " if uuid_needed && !cmd.uuid.nil?
    out << "#{message}\n"
    target = !data.nil? ? data : output
    target << out.join
  end

  private

  # Pluralize word based on a count
  #
  # @api private
  def pluralize(count, word)
    "#{word}#{'s' unless count.to_i == 1}"
  end

  # @api private
  def success_or_failure(status)
    if status.zero?
      decorate('successful', :green, :bold)
    else
      decorate('failed', :red, :bold)
    end
  end
end
