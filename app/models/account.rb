# frozen_string_literal: true

# A lightweight, non-persisted reference to an identity account.
#
# Billing has no Account table of its own — accounts live in identity and
# are referenced polymorphically (owner_type: "Account", owner_id: <uuid>).
# This value object lets ask-tokens' wallet store resolve an owner without a
# full ActiveRecord model.
class Account
  attr_reader :id

  def initialize(id)
    @id = id
  end
end
