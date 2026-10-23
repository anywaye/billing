# frozen_string_literal: true

require "jwt"
require "base64"

module TestSupport
  # Mints tokens, the way identity would.
  #
  # Every case in the suite that needs a *wrong* token needs it to be wrong in
  # one specific way, and building it here rather than inline keeps the
  # difference visible: a test that signs with the wrong key and a test that
  # tampers with the payload after signing are different attacks, and reading
  # them as `signed_token(key, ...)` and `tampered_token(...)` says which.
  module Tokens
    ALGORITHM = "RS256"
    JWKS_PATH = "/.well-known/jwks.json"

    module_function

    # A token identity would mint. `overrides` replaces claims, `header`
    # replaces protected-header fields.
    def signed_token(key, claims = {}, header = {}, algorithm: ALGORITHM)
      JWT.encode(claims, key.private_key, algorithm, { "kid" => key.kid, "typ" => "JWT" }.merge(header))
    end

    # A token that claims to be from `issuer`, valid for `audience`, and carries
    # the claims core says an access token carries. Every case starts from this
    # and changes exactly one thing, so a failure names the thing that changed.
    def access_token(key, issuer:, audience:, now:, sub: "usr_01J9Z8QK5M4N7P2R3T6V8W9X0A",
                     account_id: "acc_01J9Z8QK5M4N7P2R3T6V8W9X0A", scopes: %w[billing:read billing:write],
                     token_id: "jti_01J9Z8QK5M4N7P2R3T6V8W9X0A", extra: {}, header: {})
      claims = {
        "iss" => issuer,
        "aud" => audience,
        "sub" => sub,
        "exp" => now.to_i + 900,
        "iat" => now.to_i,
        "jti" => token_id,
        "account_id" => account_id,
        "scopes" => scopes
      }
      signed_token(key, claims.merge(extra), header)
    end

    # Rewrites a token's payload without re-signing it: a caller editing their
    # own `sub` or widening their own `scope`. The signature must stop matching.
    def tampered_payload(token, claims)
      header, _payload, signature = token.split(".")
      raise ArgumentError, "tampered_payload: not a compact JWS" unless header && signature

      [ header, base64url(claims), signature ].join(".")
    end

    # Rewrites a token's protected header without re-signing it. This is what an
    # algorithm-confusion attempt actually looks like: the header says one
    # algorithm and the signature is another, and a verifier that takes `alg` at
    # face value picks the wrong verification routine.
    def with_header(token, overrides)
      header, payload, signature = token.split(".")
      raise ArgumentError, "with_header: not a compact JWS" unless header && signature

      decoded = JSON.parse(Base64.urlsafe_decode64(pad(header)))
      [ base64url(decoded.merge(overrides)), payload, signature ].join(".")
    end

    def pad(segment)
      segment + ("=" * ((4 - (segment.length % 4)) % 4))
    end

    # A compact JWS with no signature at all — what `alg: none` looks like, and
    # the classic JWT break. Nothing verifies it, so nothing may accept it.
    def unsigned_token(claims, header)
      [ base64url(header), base64url(claims), "" ].join(".")
    end

    # A token signed with HS256 using the *public* key's modulus as the shared
    # secret: the other half of algorithm confusion, where the verifier is
    # talked into using its RSA key material as an HMAC secret.
    def hs256_token(claims, secret:, kid: "key-1", header: {})
      JWT.encode(claims, secret, "HS256", { "kid" => kid, "typ" => "JWT" }.merge(header))
    end

    def base64url(value)
      Base64.urlsafe_encode64(JSON.generate(value), padding: false)
    end
  end
end
