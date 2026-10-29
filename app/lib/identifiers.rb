# The shape of an identifier, in one place.
#
# This service has three places that need to recognise a uuid — the customer
# owner's cross-service reference, the event subject, and the `:id` of a request
# before it is turned into a query — and they have to agree, or one of them
# starts answering 422 where another answers 500.
module Identifiers
  UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
end
