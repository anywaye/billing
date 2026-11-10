# frozen_string_literal: true

module V1
  module Service
    # Token wallet metering for platform services.
    #
    # Every endpoint is keyed by `owner_key`, the namespaced owner string the
    # calling service chose (for example `boax:org_123`). The wallet math is the
    # same as the account-scoped surface: balance, grant, deduct, adjust. Cost
    # computation — what activity costs how many tokens — is the caller's job.
    class TokenWalletsController < BaseController
      rescue_from Ask::Tokens::InsufficientTokens, with: :render_insufficient_tokens

      # GET /v1/service/token_wallets/:owner_key
      def show
        render json: { owner_key: params[:owner_key], balance: wallet.balance }, status: :ok
      end

      # POST /v1/service/token_wallets/:owner_key/grant  { amount:, reason:, expires_at: }
      def grant
        amount = params.require(:amount).to_i
        reason = params.require(:reason).to_s
        expires_at = params[:expires_at].present? ? Time.parse(params[:expires_at].to_s) : nil
        entry = wallet.grant!(amount, reason: reason, expires_at: expires_at, metadata: params[:metadata] || {})
        render json: serialize_entry(entry), status: :created
      end

      # POST /v1/service/token_wallets/:owner_key/deduct  { amount:, reason: }
      def deduct
        amount = params.require(:amount).to_i
        reason = params.require(:reason).to_s
        entry = wallet.deduct!(amount, reason: reason, metadata: params[:metadata] || {})
        render json: serialize_entry(entry), status: :ok
      end

      # POST /v1/service/token_wallets/:owner_key/adjust  { amount:, reason: }
      def adjust
        amount = params.require(:amount).to_i
        reason = params.require(:reason).to_s
        entry = wallet.adjust_balance_to!(amount, reason: reason, metadata: params[:metadata] || {})
        render json: (entry ? serialize_entry(entry) : { balance: wallet.balance }), status: :ok
      end

      private
        def serialize_entry(entry)
          {
            id: entry.id,
            kind: entry.kind.to_s,
            amount: entry.amount,
            balance: entry.balance,
            reason: entry.reason,
            expires_at: entry.expires_at,
            created_at: entry.created_at,
            metadata: entry.metadata
          }
        end

        def render_insufficient_tokens(exception)
          render_problem(:insufficient_tokens, detail: "Insufficient tokens: need #{exception.required}, have #{exception.available}.")
        end
    end
  end
end
