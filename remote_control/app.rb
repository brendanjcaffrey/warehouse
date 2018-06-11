acceptable_commands = ['next', 'prev', 'playpause']
pipe_file = File.expand_path(File.dirname(__FILE__)) + '/control'

class IO
  def readline_nonblock
    rlnb_buffer = ''
    while ch = self.read_nonblock(1)
      rlnb_buffer << ch
      if ch == "\n" then
        result = rlnb_buffer
        return result
      end
    end
  end
end

App = lambda do |env|
  if Faye::WebSocket.websocket?(env)
    ws = Faye::WebSocket.new(env)

    iterations = 0
    timer = EM.add_periodic_timer(0.1) do
      begin
        while true
          fifo = open(pipe_file, 'r+')
          command = fifo.readline_nonblock.chomp
          if !acceptable_commands.include?(command)
            puts "Invalid command: #{command.inspect}"
            next
          end
          puts command.inspect
          ws.send(command)
        end
      rescue IO::WaitReadable
        iterations += 1
        if iterations > 10
          ws.send('heartbeat')
          iterations = 0
        end
      end
    end

    ws.on :close do |event|
      puts "Closed: #{event.reason}"
      ws = nil
      timer.cancel
    end

    ws.rack_response
  else
    # Normal HTTP request
    [200, {'Content-Type' => 'text/plain'}, ['Hello']]
  end
end
