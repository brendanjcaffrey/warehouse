def send_command(command)
  acceptable_commands = ['next', 'prev', 'playpause']
  if !acceptable_commands.include?(command)
    error("Only acceptable commands are #{acceptable_commands.join(", ")}")
  end

  pipe_file = File.expand_path(File.dirname(__FILE__)) + '/control'
  fifo = File.open(pipe_file, 'w')
  fifo.puts(command)
  fifo.flush
  fifo.close
end

send_command(ARGV.first.chomp)
