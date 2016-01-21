app_dir = File.expand_path(File.dirname(__FILE__))
working_directory app_dir

worker_processes 4
timeout 30

listen File.join(app_dir, 'tmp/sockets/unicorn.sock'), :backlog => 64
pid    File.join(app_dir, 'tmp/pids/unicorn.pid')

stderr_path File.join(app_dir, 'log/unicorn.stderr.log')
stdout_path File.join(app_dir, 'log/unicorn.stdout.log')
