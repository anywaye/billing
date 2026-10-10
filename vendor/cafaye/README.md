# cafaye

The shared Ruby library every cafaye Ruby service depends on, so that no service
hand-rolls token verification or the outbox insert.

It is two things, and both of them are a security incident waiting to be
hand-written:

- **JWKS-backed token verification** — RS256 bearer tokens checked against
  identity's published key set, with the algorithm allowlisted, the key set
  cached and the refresh bounded, and a frozen result that cannot carry the
  token, a claim or a key.
- **A transactional outbox writer** — core's event envelope written into a
  Postgres outbox *inside the caller's own transaction*, plus the loop that
  moves committed rows to a transport.

## Install

```ruby
# Gemfile
gem "cafaye"
```

```sh
bundle install
```

## Use

Everything below is in `test/readme_example_test.rb`, which runs it against a
real PostgreSQL and a real JWKS endpoint. If this repository is green, the
examples are not aspirational.

### 1. Configure it once

Either in `config/application.rb`, for a Rails app:

```ruby
config.cafaye.service_name    = "billing"
config.cafaye.identity_issuer = "https://identity.cafaye.com"
config.cafaye.audience        = "cafaye-services"
```

or in an initializer, in any Ruby service:

```ruby
Cafaye.configure do |config|
  config.service_name    = "billing"
  config.identity_issuer = "https://identity.cafaye.com"
  config.audience        = "cafaye-services"
end
```

That is the whole setup. Until all three are set the gem does nothing at all —
no connection, no middleware, no raise. Once they are set they are validated at
boot, so a typo is a boot failure rather than a 503 on every request.

### 2. The outbox table

```sh
rails generate cafaye:outbox     # writes db/migrate/NNNN_create_outbox_events.rb
rails db:migrate
```

Or copy `db/outbox_events.sql` into your own migration. The table is yours, in
your repository, in your database — core owns the column list, not the
migration.

### 3. Publish an event in the same transaction as the change

```ruby
class Customer < ApplicationRecord
  after_create :publish_created

  private

  def publish_created
    Cafaye.outbox.publish!(
      type: "billing.customer.created",
      subject: id,
      data: { "customer_id" => id }
    )
  end
end
```

`after_create`, never `after_commit` and never a background job: those are the
window in which the database says the customer exists and the event does not.

`publish!` **raises** if it is not inside a transaction. That is the point of the
table, and it is the one failure this library will not let you have quietly:

```ruby
Cafaye.outbox.publish!(type: "billing.customer.created", subject: id, data: {})
# => Cafaye::Errors::Outbox::NotInTransaction
```

Outside Rails, pass a connection that owns the transaction yourself:

```ruby
connection = PG::Connection.new(ENV.fetch("DATABASE_URL"))
outbox = Cafaye::Outbox::Writer.new(
  connection: Cafaye::Outbox::PgConnection.new(connection),
  service_name: "billing"
)

connection.transaction do
  connection.exec_params("insert into customers (id) values ($1)", [ id ])
  outbox.publish!(type: "billing.customer.created", subject: id, data: { "customer_id" => id })
end
```

### 4. Publish it to a transport

A separate process, never a request path. The transport is a callable, because
the transport is the service's decision:

```ruby
Cafaye::Outbox.publisher(connection: Cafaye::Outbox::ActiveRecordConnection.for(ApplicationRecord)) do |envelope|
  nats.publish(envelope.fetch("type"), JSON.generate(envelope))
end.run_once
```

Delivery is **at-least-once**, and that is a contract with consumers rather than
a limitation to paper over. What the publisher guarantees is that a redelivery
carries the *same* envelope `id`, so a consumer that dedupes on it sees one
event. Run the loop on a schedule; `for update skip locked` means N replicas can
run it against one table.

### 5. Verify a token

```ruby
principal = Cafaye.token_verifier.verify!(request.authorization.to_s)

principal.subject    # "usr_01J9Z8…" — the user
principal.account_id # "acc_01J9Z8…" — the tenant, or nil
principal.scopes     # ["billing:read", "billing:write"] — frozen, sorted
principal.expires_at # a Time, in UTC
```

Two refusals, and the difference is the one that matters:

```ruby
begin
  principal = Cafaye.token_verifier.verify!(token)
rescue Cafaye::Errors::TokenInvalid    # 401 — the token is not acceptable
rescue Cafaye::Errors::JwksUnavailable # 503 — identity's keys could not be fetched
end
```

`JwksUnavailable` is a separate class on purpose. identity being unreachable is
not the caller's credential failing, and a 401 there sends an operator to rotate
a token that was fine.

The key set is cached, and a `kid` that is not in it buys **one** forced refresh
per interval rather than one per request — a `kid` is attacker-chosen, and
"refresh on unknown kid" without a budget is an amplifier aimed at a dependency.

### 6. Nothing logged can have come from a token

`Cafaye::Token` is a string that will not print itself:

```ruby
token = Cafaye::Token.new(authorization_header)
"#{token}"       # => "[REDACTED]"
token.to_s       # => "[REDACTED]"
token.inspect    # => "#<Cafaye::Token [REDACTED]>"
token.reveal     # the value, and the only way to read it
```

A truncation rule is not a redaction rule: eight characters of a bearer token
are eight characters of a bearer token. The rule is *none of it*, and
`test/canary_test.rb` is what holds it there.

## What this gem will not do

- **It will not publish outside a transaction.** `publish!` raises.
- **It will not accept an algorithm the key set does not use.** RS256 only, from
  a constant, checked before any key is fetched. `alg: none` and HS256 are
  refused with no outbound request.
- **It will not tell you the token is invalid when identity is down.** That is a
  503 and a different exception.
- **It will not pick a broker.** The transport is a callable you supply.
- **It will not open a second connection for the outbox.** The Active Record
  adapter leases the connection your transaction is already on, because a second
  one would commit the event on its own.

## Development

```sh
mise install     # once per clone
bin/prime        # bundle, database, rubocop, bundler-audit, minitest
```

`bin/prime` creates its own test database from the reference DDL, so a clean
checkout primes with no manual step. Point it elsewhere with
`CAFAYE_TEST_DATABASE_URL`. [AGENTS.md](AGENTS.md) has the rules a change here is
held to; [CHANGELOG.md](CHANGELOG.md) has what changed.

## Licence

MIT. See [LICENSE.txt](LICENSE.txt).
