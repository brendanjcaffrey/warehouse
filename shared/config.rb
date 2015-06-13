require 'yaml'

module Config
  module_function

  def set_env(env)
    @env = env
  end

  def vals
    @vals ||= begin
      YAML.load(File.open('config.yaml'))
    rescue ArgumentError => e
      puts "Could not parse config: #{e.message}"
      exit
    end
  end

  def [](key)
    if @env.nil? || !['local', 'remote'].include?(@env)
      puts 'Invalid config environment'
      exit
    end

    vals[@env][key]
  end
end
