require 'yaml'

module Config
  module_function

  def set_env(env)
    @env = env
  end

  def remote?
    @env == 'remote'
  end

  def vals
    @vals ||= begin
      YAML.safe_load(File.open('config.yaml'))
    rescue ArgumentError => e
      puts "Could not parse config: #{e.message}"
      exit
    end
  end

  def local(key)
    vals['local'][key]
  end

  def remote(key)
    vals['remote'][key]
  end

  def [](key)
    if @env.nil? || !%w[local remote].include?(@env)
      puts 'Invalid config environment'
      exit
    end

    vals[@env][key]
  end
end
