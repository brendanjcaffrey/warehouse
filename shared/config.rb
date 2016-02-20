require 'yaml'

module Config
  module_function

  def set_env(env)
    @env = env
  end

  def remote?
    @env == 'remote'
  end

  def set_use_persistent_db(val)
    @use_persistent_db = val
  end

  def use_persistent_db?
    @use_persistent_db
  end

  def vals
    @vals ||= begin
      YAML.load(File.open('config.yaml'))
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
    if @env.nil? || !['local', 'remote'].include?(@env)
      puts 'Invalid config environment'
      exit
    end

    vals[@env][key]
  end
end
