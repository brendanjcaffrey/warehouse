require 'open3'

class Runner
  attr_reader :cmd, :exit_status, :stdout, :stderr

  def self.run(*cmd)
    Runner.new(*cmd).run
  end

  Error = Class.new(StandardError)

  def initialize(cmd)
    @cmd = cmd
    @stdout = +''
    @stderr = +''
    @exit_status = nil
  end

  def success?
    exit_status.zero?
  end

  def run
    Open3.popen3(cmd) do |stdin, stdout, stderr, wait_thr|
      until [stdout, stderr].all?(&:eof?)
        readable = IO.select([stdout, stderr])
        next unless readable&.first

        readable.first.each do |stream|
          data = +''
          begin
            stream.read_nonblock(1024, data)
          rescue EOFError
            # ignore, it's expected for read_nonblock to raise EOFError when all is read
          end

          if stream == stdout
            @stdout << data
          else
            @stderr << data
          end
        end
      end
      @exit_status = wait_thr.value.exitstatus
    end

    self
  end
end
