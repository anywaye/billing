class GrantAppRoleOnAskTokens < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE ask_tokens_wallets, ask_tokens_transactions TO billing_app;
      GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO billing_app;
    SQL
  end

  def down
    execute <<~SQL
      REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLE ask_tokens_wallets, ask_tokens_transactions FROM billing_app;
    SQL
  end
end
