grant usage on schema public to billing_app;
grant usage on schema anywaye to billing_app;


grant select, insert, update, delete on table customers to billing_app;
grant select, insert, update, delete on table ask_tokens_wallets, ask_tokens_transactions to billing_app;


grant select, insert, update, delete on table plans to billing_app;
grant select, insert, update, delete on table processor_webhooks to billing_app;
grant select, insert, update, delete on table idempotency_keys to billing_app;
grant select, insert, update, delete on table outbox_events to billing_app;

do $$
declare seq_name text;
begin
  for seq_name in
    select format('%I.%I', n.nspname, s.relname)
      from pg_class s
      join pg_namespace n on n.oid = s.relnamespace
     where s.relkind = 'S' and n.nspname = 'public'
  loop
    execute format('grant usage on sequence %s to billing_app', seq_name);
  end loop;
end $$;
