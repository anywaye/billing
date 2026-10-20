module V1
  # Token wallet for the authenticated account. Backed by ask-tokens.
  #
  # Cost computation (which activity costs how many tokens) is the caller's
  # job — this controller only does wallet math: balance, grant, deduct,
  # adjust. A caller that runs out mid-flight gets 402.
  class TokenWalletsController < BaseController
    rescue_from Ask::Tokens::InsufficientTokens, with: :render_insufficient_tokens

    # GET /v1/token_wallet
    def show
      wallet = account_wallet
      render json: { balance: wallet.balance }, status: :ok
    end

    # GET /v1/token_wallet/entries
    def entries
      wallet = account_wallet
      render json: wallet.entries.map { |e| serialize_entry(e) }, status: :ok
    end

    # POST /v1/token_wallet/grant  { amount:, reason:, expires_at: }
    def grant
      amount = params.require(:amount).to_i
      reason = params.require(:reason).to_s
      expires_at = params[:expires_at].present? ? Time.parse(params[:expires_at].to_s) : nil
      entry = account_wallet.grant!(amount, reason: reason, expires_at: expires_at, metadata: params[:metadata] || {})
      render json: serialize_entry(entry), status: :created
    end

    # POST /v1/token_wallet/deduct  { amount:, reason: }
    def deduct
      amount = params.require(:amount).to_i
      reason = params.require(:reason).to_s
      entry = account_wallet.deduct!(amount, reason: reason, metadata: params[:metadata] || {})
      render json: serialize_entry(entry), status: :ok
    end

    # POST /v1/token_wallet/adjust  { amount:, reason: }
    def adjust
      amount = params.require(:amount).to_i
      reason = params.require(:reason).to_s
      entry = account_wallet.adjust_balance_to!(amount, reason: reason, metadata: params[:metadata] || {})
      render json: (entry ? serialize_entry(entry) : { balance: account_wallet.balance }), status: :ok
    end

    private

    def account_wallet
      Ask::Tokens.wallet_for(Account.new(current_account_id))
    end

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
