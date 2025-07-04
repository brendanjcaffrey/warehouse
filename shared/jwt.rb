# frozen_string_literal: true

require 'jwt'

JWT_ALGO = 'HS256'
JWT_EXPIRY = 365 * 24 * 60 * 60

def decode_jwt(token, secret)
  JWT.decode(token, secret, true, { algorithm: JWT_ALGO })
end

def build_jwt(username, _secret)
  headers = { exp: Time.now.to_i + JWT_EXPIRY }
  JWT.encode({ username: username }, Config.env.secret, JWT_ALGO, headers)
end
