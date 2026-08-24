module Helpers
  def query(sql, params = [])
    result = nil
    DB_POOL.with do |conn|
      result = conn.exec_params(sql, params)
    end
    result.to_a
  end

  def update_query(sql, params = [])
    result = nil
    DB_POOL.with do |conn|
      result = conn.exec_params(sql, params)
    end
    result.cmd_tuples
  end

  # avplayer can't be given an authorization header, so the watch streams the
  # file routes with the token in a cookie instead. only those routes take it:
  # a cookie rides along on requests this app didn't make, & the api can write
  # to the library, so the bearer header stays the only way in there
  TOKEN_COOKIE = 'token'.freeze

  def bearer_token
    auth_header = request.env['HTTP_AUTHORIZATION']
    return nil if auth_header.nil? || !auth_header.start_with?('Bearer ')

    auth_header.gsub('Bearer ', '')
  end

  def get_validated_username(allow_export_user: false, allow_cookie: false)
    token = bearer_token
    token = request.cookies[TOKEN_COOKIE] if token.nil? && allow_cookie
    return nil if token.nil? || token.empty?

    begin
      payload, header = decode_jwt(token, Config.env.secret)
    rescue StandardError
      return nil
    end

    exp = header['exp']
    return nil if exp.nil? || Time.now > Time.at(exp.to_i)

    username = payload['username']
    valid = Config.valid_username?(username) || (allow_export_user && username == 'export_driver_update_library')
    return nil unless valid

    username
  end

  def authed?(allow_export_user: false, allow_cookie: false)
    !get_validated_username(allow_export_user: allow_export_user, allow_cookie: allow_cookie).nil?
  end

  def track_exists?(track_id)
    rows = query(TRACK_EXISTS_SQL, [track_id])
    count = rows.empty? ? 0 : rows[0]['count'].to_i
    count.positive?
  end

  def timestamp_to_ns(time_str)
    time = Time.strptime("#{time_str} UTC", '%Y-%m-%d %H:%M:%S.%N %Z')
    (time.to_i * 1_000_000_000) + time.nsec
  end
end
