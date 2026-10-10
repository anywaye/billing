# frozen_string_literal: true

require "time"

module Cafaye
  # The error hierarchy. Every failure this library raises is one of these, and
  # each one carries a `code` a caller can branch on instead of matching on a
  # message.
  #
  # The messages are the whole design of this file: **none of them interpolates
  # anything from a token, a claim, a key, a key set, or a body.** A message
  # is the one part of an exception that is copied by hand into an issue tracker
  # and pasted into a chat, and it is the one part that is very often logged at
  # a level nobody chose. A verifier that said `expected iss "https://
  # identity.internal-…" but got "…"` has put the platform's internals in a
  # string that will be read by whoever opens the next incident.
  #
  # So the messages name the *category* of the failure and the *claim* it was
  # about, and never the value. `Cafaye::TokenInvalid` says which claim was
  # wrong, because a caller fixing a misconfiguration needs that; it does not
  # say what the claim said, and it does not carry the token.
  module Errors
    # The base of everything this library raises.
    class Error < StandardError
      # A stable, machine-readable name. Safe to log, safe to put in a
      # `problem+json` body, safe to branch on.
      def code
        self.class.name.split("::").last
          .gsub(/([a-z\d])([A-Z])/, '\1_\2')
          .sub(/_error\z/, "")
          .downcase
      end
    end

    # The token is not acceptable. A 401, never a 403 and never a 500: the
    # caller presented something this door does not open, and the reason is
    # theirs to fix.
    #
    # The subclass is the reason, and there is one per refusal, because "your
    # token is bad" is not an actionable answer and a single error class with a
    # message per case is a class nobody can rescue on. The five cases a caller
    # can act on differently: the algorithm is not one we accept, no key by that
    # `kid` is published, the signature does not verify, a claim is out of range
    # or absent, or the token is not a token.
    class TokenInvalid < Error; end

    # `alg` is not in the allowlist. Covers `none`, HS256 and every symmetric
    # algorithm, and it is decided from the protected header before any key is
    # fetched, so an attacker cannot aim an outbound request at identity by
    # choosing an algorithm.
    class AlgorithmNotAllowed < TokenInvalid; end

    # The protected header names no usable `kid`, or names one the key set does
    # not publish after a refresh.
    class UnknownKey < TokenInvalid; end

    # The signature does not verify against the published key. The forged-token
    # case, and the only one where the answer is emphatically no.
    class SignatureInvalid < TokenInvalid; end

    # A registered claim is absent, out of range, or not the type it must be.
    # `claim` names *which* claim, which is the one piece of the token this
    # library is willing to talk about: it is a fixed, RFC-named string from a
    # closed list, never a value.
    class ClaimInvalid < TokenInvalid
      attr_reader :claim

      def initialize(claim)
        @claim = claim
        super("token claim '#{sanitize_claim(claim)}' is not valid")
      end

      private

      # The claim name is interpolated, and it comes from a token, so it is
      # checked against the RFC's own vocabulary before it goes in a message. A
      # claim called `<script>` is a claim name that could not exist in a
      # correctly-issued token, and this library does not put attacker text in an
      # exception message even when the message will be logged.
      def sanitize_claim(claim)
        text = claim.to_s
        return "unknown" unless /\A[a-z][a-z_]{0,31}\z/.match?(text)

        text
      end
    end

    # The signing keys could not be fetched, or the key set is not a key set.
    #
    # A separate class from `TokenInvalid` on purpose, and it is the single most
    # important distinction in the file: identity being unreachable is **not**
    # the caller's credential failing. Answering 401 here sends an operator to
    # rotate a token that was fine, which is how a dependency outage becomes a
    # fleet-wide credential incident. This is a 503 — "we cannot tell" — and
    # `guard`'s AGENTS.md states the same rule for the same reason.
    class JwksUnavailable < Error; end

    # Configuration is wrong, and it is wrong now rather than at the first
    # request. An unconfigured library is inert; a *misconfigured* one raises
    # here, because a typo in an environment variable that only surfaces as a
    # 503 on every request is a typo nobody finds.
    class ConfigurationError < Error; end

    # The outbox.
    module Outbox
      # The base of the outbox's failures.
      class Error < ::Cafaye::Errors::Error; end

      # The envelope does not satisfy core's event-envelope.schema.json. Raised
      # *before* the insert, so a malformed envelope fails at the one place that
      # wrote it rather than at every consumer on the platform.
      class EnvelopeInvalid < Error; end

      # `publish!` was called outside a transaction.
      #
      # This is the failure the whole table exists to make impossible, so it is
      # the one failure the library will not let you have. `require_transaction`
      # turns it off, and the reason to turn it off is a decision recorded
      # somewhere, not a convenience.
      class NotInTransaction < Error; end

      # The transport the publisher delivers to refused the event, or the
      # publish attempt exceeded its budget. The row stays unpublished; that is
      # the design, not a bug to paper over.
      class DeliveryFailed < Error; end
    end
  end
end
