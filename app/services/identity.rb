# Identity, as this service sees it: one issuer, one token format, one answer to
# "who is calling".
#
# `identity` is the only issuer in anywaye (core's openapi-conventions.md, "Auth"),
# so everything about verifying a caller lives in this namespace and nowhere else.
# There is no second path: a resolver seam that a deployment can point somewhere
# else would be a second trust path to `/v1`, and the webhook already teaches the
# opposite lesson — one door, one credential, one way it is checked.
#
# ## Three refusals, and they are not the same answer
#
#   * `Unconfigured` — this service has no issuer or no audience to verify against.
#     **Our** misconfiguration, and the same reasoning the webhook uses for a
#     missing signing secret: saying "your token is bad" sends an operator to the
#     wrong system. The caller did nothing.
#   * `Unreachable` — identity's key set could not be fetched, so this service
#     cannot tell whether the token is good. A 401 here would tell a caller holding
#     a perfectly valid credential to go and rotate it.
#   * `Invalid` — the token itself: absent, malformed, the wrong algorithm, signed
#     by a key identity does not publish, expired, or issued to somebody else.
#
# The two that are ours answer 503 and the one that is the caller's answers 401,
# and the distinction is the whole reason they are three classes rather than one.
module Identity
  class Error < StandardError; end

  # This deployment has no issuer, no audience, or both. `/v1` is LOCKED, not
  # served: the alternative is an API that authenticates nobody because nobody
  # configured it, which is the failure mode this whole packet exists to remove.
  class Unconfigured < Error; end

  # identity's JWKS could not be fetched. Fail closed for the same reason
  # `Unconfigured` does, and with the same answer, because from the caller's side
  # the two are the same situation: billing cannot check this credential right now.
  class Unreachable < Error; end

  # The token was read and refused. Never carries the token, and never carries a
  # library message: `detail` on a problem document is free text and the reason
  # belongs in the log with the trace id.
  class Invalid < Error; end
end
