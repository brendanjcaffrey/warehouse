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

  def get_validated_username(allow_export_user: false)
    auth_header = request.env['HTTP_AUTHORIZATION']
    return nil if auth_header.nil? || !auth_header.start_with?('Bearer ')

    token = auth_header.gsub('Bearer ', '')
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

  def authed?(allow_export_user: false)
    !get_validated_username(allow_export_user: allow_export_user).nil?
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
