# frozen_string_literal: true

# A non-persisted reference to an owner that lives outside billing.
#
# The token wallet is polymorphic (`ask_tokens_wallets.owner_type`/`owner_id`), so
# any object with an `id` can own one. `Account` is the identity-account case;
# this is the generic case for a platform service that meters usage against its
# own entity (for example a boax organization). `id` is a namespaced key such as
# `boax:org_123`, so a wallet cannot collide with another service's key.
class ExternalTokenOwner
  attr_reader :id

  def initialize(id)
    @id = id
  end
end
