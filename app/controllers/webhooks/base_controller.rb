module Webhooks
  # Shared behaviour for processor webhook endpoints: the raw body, the signed
  # header, and nothing else.
  #
  # Inbound webhooks are not JWT-authenticated — the sender is a processor, not a
  # anywaye client, and it authenticates by signature instead. That is why nothing
  # here adds a token check, and why it must never grow one: a `Bearer` token on
  # this path would be a second, weaker trust path to the same door.
  #
  # The error envelope is *not* redefined here. `ApplicationController` already
  # carries `ProblemResponses` and `RequestTraceId`, and every non-2xx in this
  # service is built by `app/lib/problem.rb`. A second renderer here would be a
  # second error shape on the same service, and the only thing that would tell
  # them apart is which controller answered.
  class BaseController < ApplicationController
    private
      # The body exactly as it arrived, byte for byte. Signature verification is
      # over these bytes and nothing else: re-serializing the parsed JSON and
      # hashing that would produce a different digest and reject every real
      # request. Reading `raw_post` rather than `params` is what makes that
      # possible, and re-parsing the verified string is what keeps the stored
      # payload identical to what the processor signed.
      #
      # Deliberately never touches `params`. Parsing is left to the ingestion
      # layer, after the signature has been checked, so an unverified body is
      # never interpreted — not even well enough to be rejected for being
      # unparseable JSON on Rails' terms rather than the processor's.
      def raw_body
        request.raw_post
      end

      def signature_header(name)
        request.headers[name]
      end
  end
end
