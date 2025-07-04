require 'yaml'

LocalConfig = Struct.new(:music_path, :artwork_path, :database_username, :database_password, :database_name, :update_library, :secret, :port, keyword_init: true)
RemoteConfig = Struct.new(:base_url, :music_path, :artwork_path, :database_username, :database_password, :database_name, :update_library, :secret, :socket_path, keyword_init: true)
UserConfig = Struct.new(:username, :password, :track_updates)

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

  def local
    @local ||= LocalConfig.new(vals['local'])
  end

  def remote
    @remote ||= RemoteConfig.new(vals['remote'])
  end

  def env
    remote? ? remote : local
  end

  def users
    @users ||= vals['users'].map do |username, values|
      UserConfig.new(username, values['password'], values['track_updates'])
    end
  end

  def valid_username?(username)
    users.any? do |user|
      user.username == username
    end
  end

  def valid_username_and_password?(username, password)
    users.any? do |user|
      user.username == username && user.password == password
    end
  end

  def track_user_changes?(username)
    users.find { |user| user.username == username }&.track_updates || false
  end
end
