

alter table customers enable row level security;
alter table customers force row level security;

drop policy if exists customers_anywaye_select on customers;
drop policy if exists customers_anywaye_insert on customers;
drop policy if exists customers_anywaye_update on customers;
drop policy if exists customers_anywaye_delete on customers;
drop policy if exists customers_anywaye_resolve on customers;

create policy customers_anywaye_select on customers for select to billing, billing_app using (owner_type = 'Account' and owner_id = (select anywaye.current_account_id()));
create policy customers_anywaye_insert on customers for insert to billing, billing_app with check (owner_type = 'Account' and owner_id = (select anywaye.current_account_id()));
create policy customers_anywaye_update on customers for update to billing, billing_app using (owner_type = 'Account' and owner_id = (select anywaye.current_account_id())) with check (owner_type = 'Account' and owner_id = (select anywaye.current_account_id()));
create policy customers_anywaye_delete on customers for delete to billing, billing_app using (owner_type = 'Account' and owner_id = (select anywaye.current_account_id()));


create policy customers_anywaye_resolve on customers for select to billing, billing_app using (id::text = (select anywaye.current_credential_digest()) or processor_customer_id = (select anywaye.current_credential_digest()));

revoke all on table customers from public;




select anywaye.protect_table('subscriptions', 'billing_app');
select anywaye.protect_table('charges', 'billing_app');
