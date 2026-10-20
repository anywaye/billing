require "test_helper"

# Contract test against core's frozen event envelope schema.
#
# PLAN.md §3: "Contract tests pass against the `core` specs for every
# API/event touched." This is that test for the three events billing-02 emits.
#
# It reads core's real schema rather than restating it, so a change in core is
# caught here instead of being discovered by a consumer's SDK. When core is not
# on disk — a standalone service checkout, where `core` is a different
# repository — the test skips and says so rather than passing vacuously.
class OutboxEnvelopeContractTest < ActiveSupport::TestCase
  ENVELOPE_SCHEMA = "schemas/event-envelope.schema.json"
  MANIFEST = "cafaye.yml"

  # Events this service publishes that core's catalog has no row for. The packet
  # asks for a plan-update event and core's catalog is a different repository,
  # so the row is an action item there, not something this worktree can land.
  # See the DECISION NEEDED in cafaye.yml. This list is the mechanical half of
  # that obligation: core's own suite only checks core's example manifests, and
  # `caf contract lint` does not exist yet, so without this a new event type
  # published here with no catalog row would pass every suite in the system.
  PENDING_CORE_CATALOG_ROWS = %w[billing.plan.updated].freeze

  # Events whose `data` does not satisfy the payload schema core declares for
  # them, and exactly how it differs. **Empty in billing-04. Five entries in
  # billing-05, every one of them opened by core-03 rather than by anything in
  # this repository.**
  #
  # billing-04 closed this table against core v0.2, which shipped two payload
  # schemas. core-03 shipped all eight, and five of them describe a payload this
  # build does not emit:
  #
  #   * `billing.plan.created` and `billing.plan.updated` are closed with
  #     `additionalProperties: false` and do not name `entitlements`, which
  #     billing-04 added to `Plan#as_json`.
  #   * `billing.subscription.started`, `.updated` and `.canceled` are core's
  #     *processor-normalised* shape — the one billing-03b emitted — while
  #     billing-04 moved the three subscription events onto billing's own ids:
  #     `subscription_id` is `Subscription#id`, which is also the envelope's
  #     `subject`, with `plan_id`, `account_id`, `currency`, `started_at` and
  #     `processor_subscription_id` around it and no `kind`.
  #
  # The second one is a spec question, not a bug in a payload, and it is recorded
  # rather than paid for. core's D10 gives the reason the schema was rewritten as
  # "billing has no subscriptions table and cannot invent ids it does not have" —
  # true of billing-03b, which is what core-03 read, and not true of billing-04,
  # which added one. core's own D10 anticipates precisely this: "when billing
  # grows a subscriptions table, the shape moves again … that is a second breaking
  # change." That second breaking change is core's to make, core is read-only from
  # a service worktree, and the two ways to make the test green without it — emit a
  # payload nobody has agreed to, or drop the ids a consumer needs — are both the
  # spec changing without a decision. So the difference is written down here and
  # in `cafaye.yml`, and asked of the manager.
  #
  # `entitlements` is the same shape of problem at smaller scale: core's plan
  # schema is missing a field this publisher has always sent. Removing it from the
  # payload is a contract change this worktree does not get to make, and the plan
  # payload is the same shape an HTTP response uses, so it cannot be quietly
  # narrowed here either.
  #
  # ## The recipient fact and the plan's name were a gap, and core closed it
  #
  # billing-event-payloads-01 added `email` to the two payment types and `email`
  # and `plan_name` to the three subscription types, and both were recorded here
  # the day they were added, because core's schemas were closed with
  # `additionalProperties: false` and declared neither. They are **not here now**,
  # and the direction that matters is that nothing in this repository removed
  # them: they stopped being gaps because core's own commit `b8ae8fb`
  # ("billing's money events: declare the recipient and the plan name", core-w46)
  # declared them **the way billing already sends them** — `email` OPTIONAL and
  # NEVER NULL, because `with_recipient`/`core_payload` merge it only when
  # `customers.email` is present, and `plan_name` REQUIRED and non-empty, because
  # `core_payload` writes it unconditionally from a column that is `null: false`
  # with a presence validation.
  #
  # So the two payment events are the **first money events to match core's
  # schemas exactly**, and the three subscription events each lost two fields
  # from their `unexpected` list. The PII direction of travel is unchanged: the
  # fields are still on the wire, `email` still resolved by one indexed lookup on
  # `customers.processor_customer_id`, and the schema that now declares them was
  # written to fit the emitter rather than the reverse. A gap this table records
  # closing from the core side is the mechanism working, and the two-way
  # assertion is what caught it — a table subtracted from the failures would have
  # left these entries sitting here, describing a disagreement that no longer
  # existed.
  #
  # Asserted as a set rather than subtracted from the failures. Subtracting would
  # let a payload that starts matching sit here forever, and would let a new event
  # stop matching without anyone noticing. A set means a difference in either
  # direction fails, and that is exactly the failure this commit pays off: the
  # difference was in the *closing* direction.
  PENDING_PAYLOAD_ALIGNMENT = {
    "billing.plan.created" => {
      unexpected: %w[entitlements]
    },
    "billing.plan.updated" => {
      unexpected: %w[entitlements]
    },
    # Measured on this stack (2026-10-16): the first checkout's `invoice.paid`
    # arrives before `customer.subscription.created`, so the charge recorder
    # needs the cafaye link the Checkout session put in the invoice's metadata —
    # without it, a real payment recorded no receipt. The key is emitted because
    # a consumer needs it (the same argument the subscription payloads won), and
    # core's payment schema is closed and does not declare it: recorded here and
    # in cafaye.yml as the gap it is, not worked around by narrowing the event.
    "billing.payment.succeeded" => {
      unexpected: %w[cafaye_customer_id]
    },
    "billing.payment.failed" => {
      unexpected: %w[cafaye_customer_id]
    },
    # core's D10 shape: `kind`, `processor` and `processor_event_id` are required
    # by core and absent here, and the four cafaye ids are rejected by a schema
    # closed with `additionalProperties: false`. `email` and `plan_name` were
    # here until core-w46 (`b8ae8fb`) declared them; see the note above.
    "billing.subscription.started" => {
      missing: %w[customer_id kind processor processor_event_id],
      unexpected: %w[account_id currency plan_id started_at]
    },
    "billing.subscription.updated" => {
      missing: %w[customer_id kind],
      unexpected: %w[account_id currency plan_id processor_subscription_id]
    },
    "billing.subscription.canceled" => {
      missing: %w[customer_id kind],
      unexpected: %w[account_id currency plan_id processor_subscription_id]
    }
  }.freeze

  # core's pattern for each id in a payload it declares, and the reason this
  # service's emitted value does not meet it. **Empty in billing-05.**
  #
  # The one entry this table held was `billing.subscription.started` with three
  # fields, and core-03 settles each of the three on its own. D10 rewrote
  # `schemas/events/billing/subscription/started.schema.json`:
  #
  #   * `subscription_id` — core still declares the property, but as
  #     `{"type": "string", "minLength": 1}` with **no `pattern`**. The
  #     `^sub_[0-9A-Z]{26}$` this entry recorded is gone, so there is nothing left
  #     for a uuid to fail to match.
  #   * `plan_id` — core's schema does not declare the property at all. A field
  #     core does not name cannot constrain an id.
  #   * `account_id` — the same, for the same reason.
  #
  # The mechanism this table exists for is *removal*: an entry is meant to go when
  # the gap closes, and a value that starts matching is supposed to fail rather
  # than sit here. D10 closed all three from the core side, which is the same
  # outcome by the other road, so the removal is the point of the mechanism rather
  # than a workaround for it.
  #
  # What replaced it is not a loop over a table that may be empty. An empty table
  # iterated zero times exits 0 having checked nothing, and a test that proves
  # nothing is worse than no test — so the assertion below *derives* the gap from
  # core's files and the payloads this build emits, and compares. It cannot pass
  # vacuously, because the work it does is over core's schemas, not over this
  # constant. The corpus and the grammar comparison move with it, onto the two
  # constraints where core and this service genuinely each hold a pattern of their
  # own: `Plan::SLUG_PATTERN` and `Billing::Money::CURRENCY_FORMAT`.
  PENDING_ID_PATTERNS = {}.freeze

  # The events core has no payload schema for, which core's outbox checklist asks
  # for. **Empty in billing-05**: core-03 shipped a schema for all eight of this
  # service's types, so billing owes core none, and the seven entries this held
  # were dropped deliberately rather than by arithmetic.
  #
  # It is written out rather than derived from the two tables above on purpose.
  # Subtracting `PENDING_PAYLOAD_ALIGNMENT.keys` used to stand in for "core has a
  # schema for this", which it never was — a payload can be misaligned *and* have
  # a schema, which is the ordinary case now, and the subtraction would have hidden
  # the very entries core-03 opened.
  #
  # The assertion below does not go with it: an empty table is only the passing
  # case because eight files were read on disk, and the message says both
  # directions — drop an entry core has answered, and add one for a type core has
  # not.
  NO_PAYLOAD_SCHEMA_YET = [].freeze

  # The whole vocabulary of JSON Schema this file reads, in one place, for one
  # reason: a keyword that is not on this list is a **raise**, never a skip.
  #
  # A validator that quietly ignores a constraint it does not understand reports
  # "no problem" for a document it never checked, and that is precisely the failure
  # a contract test exists to prevent — the one where a spec moved and every suite
  # stayed green. So the set is closed, `violations` refuses anything outside it,
  # and the drift test below holds it against every keyword core actually uses
  # across this service's eight payload schemas. That test is what turns "core
  # changed shape" into one named failure instead of five scattered ones.
  #
  # `$comment` is on this list and constrains nothing, which is the point rather
  # than an exception to it. JSON Schema 2020-12 §8.3 makes it a *metadata*
  # keyword: a validator is REQUIRED to ignore it, and `title`/`description` —
  # already here for the same reason — are its siblings in the same section. core
  # writes a `$comment` on every payload schema recording where the shape was
  # transcribed from, so "core's schemas grew a provenance note" arrives as a
  # constraint this validator cannot check, and the closed set would answer a
  # documentation change as if it were a contract change.
  #
  # Being *understood* here means ignored, and that is already true by
  # construction: every check below dispatches on the keyword it knows
  # (`type`, `enum`, `pattern`, …), so a listed keyword nothing dispatches on
  # cannot contribute a breach. Adding `$comment` therefore widens what the file
  # tolerates without widening what it accepts — and the drift test still fires on
  # the next keyword core genuinely starts constraining with.
  UNDERSTOOD_KEYWORDS = %w[
    $id $schema $comment title description
    type enum const format pattern
    minLength maxLength minimum maximum
    properties required additionalProperties oneOf
  ].freeze

  # The seven JSON Schema types. `type` may name one, or name an array of them
  # meaning "any one of these" — core's nullable fields are written
  # `["string", "null"]`, and reading that array as a type *name* is what made this
  # raise on core's very first nullable field. An array is a disjunction, and a
  # name outside these seven raises even inside one, so `["string", "date"]` fails
  # loudly rather than quietly accepting its string case.
  #
  # `number` accepts a Float; `integer` does not, even though JSON Schema 2020-12
  # reads `1.0` as an integer. That is the strict direction on purpose: no amount
  # in this service is ever a Float (AGENTS.md, Billing::Money), and a validator that
  # accepted one where core asked for an integer would be the exact hole this file
  # exists to close.
  JSON_TYPES = %w[string number integer boolean object array null].freeze

  # The `format`s core uses, and how each is checked. `format` is an annotation in
  # JSON Schema proper, so checking it is this test's choice — but *ignoring* it
  # would be worse, because `format: uuid` and `format: date-time` are two of the
  # ways core says "this value has a shape", and skipping them leaves two thirds of
  # a payload unchecked. A `format` outside this list raises.
  UNDERSTOOD_FORMATS = {
    "uuid" => ->(value) { Identifiers::UUID.match?(value) },
    "date-time" => ->(value) { value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/) },
    "email" => ->(value) { URI::MailTo::EMAIL_REGEXP.match?(value) }
  }.freeze

  # A `oneOf` branch, as core writes them in D11: annotations plus a list of
  # required fields, which is enough to say which of two shapes is present. A
  # branch that grew a real schema inside it would raise rather than be read as a
  # `required` list it is not.
  #
  # `$comment` is here for the reason it is in UNDERSTOOD_KEYWORDS: it is metadata,
  # ignorable at every position in a schema document, and a branch is a position.
  # core does not put one inside a `oneOf` branch today, so this line is not
  # covering anything real yet — it is here so that the day it does, the answer is
  # "ignored, as the spec requires" instead of a raise from a list that had drifted
  # one nesting level behind the vocabulary it mirrors.
  ONE_OF_BRANCH_KEYWORDS = %w[$comment title description required].freeze

  # The webhook fixtures that produce the events that do not come from a model
  # callback. Ingested for real by the fixtures under test, so the payloads
  # checked against core are the ones this build would put on the wire.
  WEBHOOK_FIXTURES = %w[
    customer.subscription.created
    customer.subscription.updated
    customer.subscription.deleted
    invoice.paid
    invoice.payment_failed
    checkout.session.completed.payment
  ].freeze

  setup do
    skip("core is not on disk; set CORE_PATH to #{default_core_path}") unless schema
    travel_to(frozen_now)
  end

  test "every event billing emits satisfies core's envelope schema" do
    envelopes.each do |envelope|
      assert_valid_envelope(envelope)
    end
  end

  test "the event type pattern this service validates against is core's" do
    assert_same_grammar schema.fetch("$defs").dig("eventType", "pattern"), OutboxEvent::TYPE_PATTERN
  end

  test "the subject pattern this service validates against is core's" do
    assert_same_grammar schema.fetch("properties").dig("subject", "pattern"), OutboxEvent::SUBJECT_PATTERN
  end

  test "an event type is anchored to the whole string, not to a line of one" do
    # core's JSON Schema pattern is written with `^` and `$`, which in a Ruby
    # Regexp anchor to a line rather than to the string. This service anchors
    # with `\A` and `\z`, which is strictly narrower: an envelope can never be
    # smuggled through by appending a second line. Narrower is the safe
    # direction, so the difference is asserted rather than papered over.
    assert_not OutboxEvent::TYPE_PATTERN.match?("billing.plan.created\nrm -rf /")
    assert_not OutboxEvent::SUBJECT_PATTERN.match?("cus_1\ntrace_id: x")
  end

  test "the source is the service name, which is what core requires of it" do
    assert_equal manifest.fetch("name"), "billing"
    envelopes.each { |envelope| assert_equal "billing", envelope.fetch("source") }
  end

  test "every type in the manifest is a type this service can emit" do
    assert_equal manifest.fetch("exposes").fetch("events").sort, OutboxEvent::TYPES.sort
  end

  test "every type this service emits has a catalog row in core" do
    catalog = core_catalog

    skip("core's catalog could not be read") if catalog.nil?

    undeclared = OutboxEvent::TYPES - catalog

    # Subtract the known debt rather than skipping: a *new* type published
    # without a catalog row still fails here, and when core lands the row the
    # difference stays empty with nothing to clean up.
    assert_empty undeclared - PENDING_CORE_CATALOG_ROWS,
      "core's catalog has no row for these, and nothing is tracking that: #{undeclared.inspect}"
  end

  test "every event payload matches core's payload schema, where one exists" do
    # core v0.2 (D3) put the payload schemas in core and the outbox checklist
    # asks for `data` to be validated against
    # `schemas/events/<service>/<entity>/<action>.schema.json` before the insert.
    # core-03 shipped all eight, so from here this is not bookkeeping at all: it is
    # the whole of `billing`'s payload contract, and it reads every keyword core
    # declares rather than the `type` and nothing else.
    assert_equal PENDING_PAYLOAD_ALIGNMENT, payload_mismatches,
      "the payloads that do not match core's schemas have changed: fix them, or record the new gap in PENDING_PAYLOAD_ALIGNMENT and in cafaye.yml"
  end

  # The one thing that says what this file can and cannot read.
  #
  # The five failures this packet reconciles were five *symptoms*: a missing
  # `pattern` key, an array where a type name was expected, two set comparisons
  # that moved. All five came from core's schemas changing shape, and nothing here
  # had noticed the shape itself. This test is the notice: it walks every
  # constraint in every payload schema core ships for this service's types, and
  # requires each keyword to be one the validator below models. A `$ref` or a
  # `dependentRequired` or a `patternProperties` tomorrow fails here, once, naming
  # the keyword, instead of turning into a scattering of KeyErrors inside other
  # tests.
  test "every keyword core's payload schemas use is one this validator understands" do
    unread = core_constraint_keywords - UNDERSTOOD_KEYWORDS

    assert_empty unread,
      "core's payload schemas now use #{unread.inspect}, which this validator does not model: " \
      "teach it, or the check silently stops covering what core declared"
  end

  # And the loud half, asserted rather than assumed: an unmodelled *type* raises
  # rather than returning true. The `else` in `value_is_type?` is a deliberate
  # refusal, and a refusal nobody exercises is a refusal that quietly becomes a
  # `rescue` in somebody's next packet — a validator that accepts what it does not
  # understand is worse than no validator, because it reports a breach as clean.
  test "the payload validator refuses a type it does not understand, rather than accepting it" do
    assert_raises(RuntimeError) { value_is_type?("date", "2026-09-30") }
    assert_raises(RuntimeError) { value_is_type?("strng", "x") }
    assert_raises(RuntimeError) { value_is_type?({ "type" => "string" }, "x") }
  end

  test "the payload validator refuses a keyword it does not understand, rather than skipping it" do
    assert_raises(RuntimeError) { violations({ "patternProperties" => {} }, {}, "slug") }
    assert_raises(RuntimeError) { violations({ "format" => "hostname" }, "cafaye.com", "site") }
  end

  # The other half of the closed set, and the reason `$comment` may sit in it.
  #
  # Being on UNDERSTOOD_KEYWORDS means IGNORED, and this is the assertion that says
  # so — because the two mistakes look identical in a diff and are opposites:
  #
  #   treating `$comment` as metadata  (correct)  — a note cannot change a verdict
  #   treating `$comment` as a constraint (wrong)  — a note in a schema file
  #                                              becomes an oracle
  #
  # The second is the more dangerous of the two, and it is what a well-meaning
  # patch to this drift looks like: "core told me id must be an integer, let me
  # read it out of the comment." It would make every payload fail, so it would be
  # caught — but a comment that *relaxes* a check would pass, and that is the
  # shape of a silent hole.
  #
  # So both directions are pinned, and pinned against a comment that says the
  # opposite of the schema: `$comment` claiming a valid payload is invalid, and
  # `$comment` claiming a breaching one is fine. Neither moves. A `$comment` that
  # is not even a string is covered too — it is metadata, so its type is nobody's
  # business, and refusing it would be the closed set refusing its own rule.
  test "a $comment is ignored as metadata, and changes no verdict in either direction" do
    # BOTH positions, and the second one is not belt-and-braces.
    #
    # `violations` is called with the *root* schema, and then again with each
    # property's constraint — so a `$comment` at the root is never seen by
    # `scalar_violations`, which receives only `{ "type" => "string" }`. A patch
    # that taught the root walk to honour comments therefore passes every
    # root-level assertion here while leaving the property level wide open, and
    # that is the level at which a per-field comment would actually arrive. core
    # writes `$comment` at the root today; "today" is not a schema constraint, and
    # a test that only covers the position core happens to use is a test of core's
    # current habit rather than of this validator's rule.
    schema_for = lambda do |where, note|
      property = { "type" => "string" }
      root = { "type" => "object", "properties" => { "id" => property }, "required" => %w[id] }
      case where
      when :root then root.merge("$comment" => note)
      when :property then root.merge("properties" => { "id" => property.merge("$comment" => note) })
      end
    end

    %i[root property].each do |where|
      label = "at the #{where} level"

      assert_empty violations(schema_for.(where, nil), { "id" => "x" }, "data"),
        "a valid payload is valid #{label} with no comment present"
      assert_empty violations(schema_for.(where, "id MUST be an integer"), { "id" => "x" }, "data"),
        "a comment demanding a stricter payload did not change a passing verdict #{label}"
      assert_equal 1, violations(schema_for.(where, nil), { "id" => 7 }, "data").length,
        "a breaching payload breaches #{label} with no comment present"
      assert_equal 1, violations(schema_for.(where, "id is fine"), { "id" => 7 }, "data").length,
        "a comment excusing a breaching payload did not change a failing verdict #{label}"
      assert_empty violations(schema_for.(where, 42), { "id" => "x" }, "data"),
        "a non-string comment is still ignored rather than refused #{label}"
      assert_equal 1, violations(schema_for.(where, { "id" => "string" }), { "id" => 7 }, "data").length,
        "a comment carrying a schema is still ignored rather than honoured #{label}"
    end
  end

  # What is left of the recorded id-pattern gap, and how it is now decided.
  #
  # The table held three fields on `billing.subscription.started`, and core-03's
  # D10 closed all three from the core side: `subscription_id` lost its
  # `^sub_[0-9A-Z]{26}$`, and `plan_id` and `account_id` are not declared as
  # properties at all. An entry that outlives its gap is the failure this table
  # exists to prevent, so the table is empty and the *assertion* is not.
  #
  # It used to be a loop over `PENDING_ID_PATTERNS`, which would now iterate zero
  # times and exit 0 having checked nothing — a skipped test in everything but name,
  # and the outcome PLAN.md §1 forbids. So the gap is **derived** instead: every
  # `pattern` core declares, anywhere in a payload schema for a type this build
  # publishes, against every value this build emits at that place. One assertion
  # covers the key set, the field set and the grammar at once, and its work is over
  # core's files rather than over this constant, so it cannot pass vacuously.
  PENDING_ID_PATTERN_TEST = "the id patterns core declares are met by every value we emit, and every one they miss is recorded"

  # The corpus the patterns are compared over. Behaviour, not text: the same
  # grammar is the same *set of accepted strings*, and `Regexp#source` is not a
  # reliable way to read one back — Ruby rewrites a pattern's source depending on
  # the encoding it was compiled in, so comparing texts passes once and fails
  # forever after with nothing changed in between. `assert_same_grammar` below is
  # the same technique the envelope patterns use, for the same reason.
  #
  # It held the cafaye-prefixed ids D10 removed, so it now holds the two
  # constraints where core and this service each declare a pattern of their own and
  # both have to be right: a plan's slug and an amount's currency. A corpus is only
  # evidence about the strings in it, so the strings in it are the ones those two
  # patterns actually decide.
  PATTERN_CORPUS = [
    # What this build emits.
    "pro-monthly",
    "USD",
    # The neighbouring shapes, where a difference in either pattern would show up.
    "pro",
    "pro_monthly",
    "Pro-Monthly",
    "-pro-monthly",
    "pro-monthly-",
    "pro--monthly",
    "pro.monthly",
    "pro/monthly",
    "pro monthly",
    "",
    "usd",
    "US",
    "USDD",
    "US1",
    "123",
    "U$D"
  ].freeze

  test PENDING_ID_PATTERN_TEST do
    assert_equal id_pattern_gaps, PENDING_ID_PATTERNS,
      "the id-format gaps have changed: a value that now meets core's pattern means the entry goes, " \
      "and a pattern core declares that a value misses means a new entry is owed"
  end

  # Two sides, one constraint, and the honest way to say they agree is behaviour.
  # `Plan::SLUG_PATTERN` is this service's answer to the same question core's plan
  # schema answers with `^[a-z0-9]+(-[a-z0-9]+)*$`, and `Billing::Money::CURRENCY_FORMAT` is
  # its answer to `^[A-Z]{3}$`. Neither is an id, but the technique is the one this
  # file was built around and the failure it guards against is the same one: a text
  # comparison passes once and fails forever after with nothing changed in between.
  test "this service's slug pattern and core's accept exactly the same strings" do
    assert_same_grammar declared_pattern("billing.plan.created", "slug"), Plan::SLUG_PATTERN, PATTERN_CORPUS
  end

  test "this service's currency pattern and core's accept exactly the same strings" do
    assert_same_grammar declared_pattern("billing.plan.created", "price.currency"), Billing::Money::CURRENCY_FORMAT, PATTERN_CORPUS
  end

  # core's patterns are written with `^` and `$`, which in a Ruby `Regexp` anchor
  # to a *line* rather than to the string, while this service anchors the whole
  # string with `\A` and `\z`. The difference is asserted rather than papered over:
  # the whole-string reading is strictly narrower, so a value can never be smuggled
  # through by appending a second line, and comparing the two on a corpus containing
  # one is meaningless without saying so.
  #
  # It runs over every pattern core declares rather than over the recorded gaps,
  # because there are no recorded gaps left, and a test that iterates an empty table
  # proves nothing. Asserting the *direction* as well as the fact keeps it honest
  # both ways: were core's patterns ever written `\A…\z`, the comparison below
  # would be vacuous, so that is stated too.
  test "core's patterns are anchored to a line, where this service reads them as anchored to the whole string" do
    patterns = core_patterns

    assert_not_empty patterns, "core declares no pattern on any payload this build publishes: re-read the schemas"

    patterns.each do |event_type, field, pattern, value|
      assert pattern.start_with?("^"),
        "core's pattern for #{event_type}.#{field} is no longer anchored with ^: re-read the schema"

      forged = "#{value}\nforged"

      assert Regexp.new(pattern).match?(forged),
        "core's pattern for #{event_type}.#{field} no longer accepts a second line, so the comparison this test draws is not the one it names"
      assert_not whole_string(pattern).match?(forged),
        "the whole-string reading of core's pattern for #{event_type}.#{field} accepts a second line, which is the direction this service must never take"
    end
  end

  test "the corpus would notice a pattern that had changed" do
    # The corpus is only evidence about the strings in it, so it is checked against
    # a pattern that is deliberately different — here, one that wants a different
    # length. Without this, a corpus of strings every plausible pattern accepts
    # would compare equal to anything and the assertions above would be decorative.
    changed = Regexp.new("^[a-z0-9]{1,20}$")

    disagreements = PATTERN_CORPUS.reject { |candidate| changed.match?(candidate) == Plan::SLUG_PATTERN.match?(candidate) }

    assert_not_empty disagreements, "the corpus cannot tell two different patterns apart"
  end

  test "the set of events with an id-pattern gap has changed" do
    assert_equal PENDING_ID_PATTERNS.keys.sort, id_pattern_gaps.keys.sort,
      "the set of events checked for an id-format gap has changed: update PENDING_ID_PATTERNS and the reason in cafaye.yml"
  end

  # core-03 shipped a payload schema for all eight types this build publishes, so
  # this table is empty and the obligation it was accounting for is discharged.
  # The assertion does not go with it: an empty table is only the passing case
  # because eight files were read on disk, and the message says both directions —
  # drop an entry core has answered, and add one for a type core has not.
  test "the set of events with no payload schema in core has changed" do
    unspecified = OutboxEvent::TYPES.reject { |event_type| payload_schema_for(event_type) }

    assert_equal NO_PAYLOAD_SCHEMA_YET.sort, unspecified.sort,
      "the set of events with no payload schema in core has changed: drop the entries this service no longer owes one for, and record the ones it still does"
  end

  # A type with no fixture here would be silently unchecked by the test above,
  # which is the failure mode a contract test exists to prevent.
  test "the events under test are every type this service publishes" do
    assert_equal OutboxEvent::TYPES.sort, envelopes.map { |envelope| envelope.fetch("type") }.uniq.sort
  end

  # The HTTP document, the router and the manifest are held to each other in
  # `test/contract/http_surface_contract_test.rb`, which does not read core and
  # so does not sit behind the `setup` above. The three checks this file used to
  # carry for the document — every path served, `info.version`, `exposes.api` —
  # moved there, and the first of them was replaced rather than moved: a
  # path-only comparison cannot see `PUT /v1/customers/{id}`, which was served
  # and documented nowhere until that packet.

  private
    # --- the fixtures under test: real emissions, not hand-built envelopes ---

    def envelopes
      @envelopes ||= emit_one_event_of_every_type
    end

    # Three of the eight events come from a model callback and five from the
    # webhook mapping. Both are produced here the way production produces them —
    # a record written, a signed fixture ingested — because an envelope assembled
    # by hand in a test is an envelope nothing has checked this service against.
    # A subscription delivery is acted on only when it resolves to a cafaye customer
    # and a cafaye plan, so the customer and the plan here carry the *processor's*
    # ids the fixtures use. Without them the three subscription fixtures would be
    # refused and there would be no subscription envelope to check against core.
    def emit_one_event_of_every_type
      # Account-owned, not user-owned, and that is load-bearing: a subscription is
      # billed to an account, and the lifecycle refuses to attach one to a customer
      # that belongs to a user — which account a user belongs to is identity's fact
      # and no event carrying it is in this build's `consumes`.
      Customer.create!(
        owner_type: "Account",
        owner_id: "11111111-1111-4111-8111-111111111111",
        processor: "stripe",
        processor_customer_id: StripeSubscriptionFixtures::PROCESSOR_CUSTOMER_ID,
        # The recipient fact this packet added to the money events. The corpus
        # customer carries one, because the payment payloads are built by
        # resolving this row through the processor's customer id — without an
        # address here, the field would be absent from every payment payload and
        # the gap recorded below would be a gap about a field nothing emitted.
        email: "billing@example.com"
      )
      plan = Plan.create!(
        name: "Pro monthly",
        slug: "pro-monthly",
        price: Billing::Money.new(1900, "USD"),
        interval: "month",
        processor_price_id: StripeSubscriptionFixtures::PROCESSOR_PRICE_ID
      )
      plan.update!(active: false)

      WEBHOOK_FIXTURES.each { |fixture| ingest(fixture) }

      OutboxEvent.order(:created_at, :id).map(&:to_envelope)
    end

    def ingest(fixture)
      body = JSON.parse(stripe_fixture(fixture))

      Webhooks::Ingestion.new(processor: :stripe, event_id: body["id"], type: body["type"], payload: body).call
    end

    # Every payload this build emits for one event type, not just the first.
    #
    # `billing.payment.succeeded` comes from two different processor deliveries — a
    # settled invoice and a completed Checkout session — and they are two different
    # shapes, because that is D11 and core's `oneOf` says so. Taking the first
    # envelope with a matching type meant the uuid tiebreaker chose which of the two
    # was checked, at random, on every run: half the contract verified on a coin
    # flip. Every one of them is checked now.
    def payloads_for(event_type)
      @payloads_for ||= {}
      @payloads_for[event_type] ||= envelopes.select { |envelope| envelope.fetch("type") == event_type }.map { |envelope| envelope.fetch("data") }
    end

    # Every way a payload disagrees with a core schema, as a hash keyed by event
    # type, so a difference in either direction fails. An empty result is the
    # passing case; anything in it that is not recorded above is a contract
    # breach, not a tolerance.
    def payload_mismatches
      OutboxEvent::TYPES.each_with_object({}) do |event_type, mismatches|
        schema = payload_schema_for(event_type)
        next if schema.nil?

        difference = payloads_for(event_type)
          .map { |data| disagreements(schema, data) }
          .reduce({}) { |merged, one| merge_disagreements(merged, one) }
          .reject { |_reason, entries| entries.empty? }

        mismatches[event_type] = difference if difference.any?
      end
    end

    # One payload against one schema, in three buckets. `missing` and `unexpected`
    # are dotted paths so a nested field is as visible as a top-level one; `invalid`
    # carries the sentence rather than the path alone, because "what is wrong with
    # it" is the part a person reading a failure actually needs. A nested breach of
    # the shape — a required key absent inside `price`, a key core does not declare
    # inside `owner` — arrives as a sentence in `invalid` rather than as a
    # top-level path, and that is the one asymmetry here.
    #
    # Every bucket is sorted. `PENDING_PAYLOAD_ALIGNMENT` is a recorded table of
    # known debt, and a table that had to be rewritten because core reordered its
    # own JSON keys would be a table about formatting rather than about contracts.
    def disagreements(schema, data)
      {
        missing: required_paths(schema, data).sort,
        unexpected: undeclared_paths(schema, data).sort,
        invalid: invalid_paths(schema, data).sort
      }
    end

    # Two envelopes of one type, merged rather than sampled: the recorded debt is
    # the union of what every emitted shape disagrees with, so one shape matching
    # cannot hide another shape's breach behind it.
    def merge_disagreements(left, right)
      left.merge(right) { |_reason, here, there| (here + there).uniq.sort }
    end

    def required_paths(schema, data, prefix = nil)
      return [] unless data.is_a?(Hash)

      here = (schema["required"] || []).reject { |name| data.key?(name) }.map { |name| dotted(prefix, name) }
      there = (schema["properties"] || {}).flat_map { |name, constraint| required_paths(constraint, data[name], dotted(prefix, name)) }

      here + there
    end

    # `additionalProperties: false` is how core closes an object, and it is what
    # makes "eight fields and nothing else" a machine-checkable claim rather than a
    # description.
    def undeclared_paths(schema, data, prefix = nil)
      return [] unless data.is_a?(Hash)
      return [] unless schema["additionalProperties"] == false

      (data.keys - (schema["properties"] || {}).keys).map { |name| dotted(prefix, name) }
    end

    # Every value-level breach, all the way down. This recursion is what makes the
    # check a schema check rather than a shape check: `price.currency` and
    # `owner.id` are constraints core declared, and a validator that stopped at the
    # top level would not have read either.
    #
    # Two things it deliberately does not do. It does not descend into a value that
    # is not an object — `properties` is a constraint *on an object*, so reporting
    # `unit_amount.amount_minor is null` under a null `unit_amount` is a fact about
    # nothing. And it does not evaluate a property the payload does not carry: an
    # absent key is `missing`, and reporting it again as an ill-typed null would say
    # the same breach twice and bury the ones that are only said once.
    def invalid_paths(schema, value, prefix = nil)
      return [] unless value.is_a?(Hash)

      (schema["properties"] || {}).filter_map { |name, constraint|
        violations(constraint, value[name], dotted(prefix, name)) if value.key?(name)
      }.flatten
    end

    def dotted(prefix, name)
      [ prefix, name ].compact.join(".")
    end

    # Every way one value disagrees with the constraint core declared for it, as
    # strings naming the field and the keyword that was broken.
    #
    # A property-by-property check, not a JSON Schema engine: a dependency that can
    # validate a document is a dependency this service does not have. What it will
    # not be is a check that skips what it cannot read — a keyword outside
    # `UNDERSTOOD_KEYWORDS` raises, because a validator that ignores a constraint
    # it does not understand reports "no problem" for a document it never checked,
    # and that is the one outcome a contract test may not have.
    def violations(constraint, value, field)
      refuse_unknown_keywords(constraint, field)

      scalar_violations(constraint, value, field) +
        one_of_violations(constraint, value, field) +
        nested_shape_sentences(constraint, value, field) +
        invalid_paths(constraint, value, field)
    end

    def refuse_unknown_keywords(constraint, field, understood = UNDERSTOOD_KEYWORDS)
      unreadable = constraint.keys - understood

      raise "this test does not understand #{unreadable.inspect} on #{field}" if unreadable.any?
    end

    # A nested breach of the *shape* rather than of one value. It is reported as a
    # sentence rather than as a path because the path is not the interesting half:
    # what a reader needs is that core asked for it and the payload does not have
    # it, which is a different sentence from the value-level ones above.
    def nested_shape_sentences(constraint, value, field)
      return [] unless value.is_a?(Hash)

      absent = (constraint["required"] || []).reject { |name| value.key?(name) }
        .map { |name| "#{field}.#{name} is required by core and is not in the payload" }
      extra = constraint["additionalProperties"] == false ? (value.keys - (constraint["properties"] || {}).keys)
        .map { |name| "#{field}.#{name} is not a property core declares" } : []

      absent + extra
    end

    def scalar_violations(constraint, value, field)
      [
        type_violation(constraint, value, field),
        enum_violation(constraint, value, field),
        const_violation(constraint, value, field),
        pattern_violation(constraint, value, field),
        bound_violations(constraint, value, field),
        format_violation(constraint, value, field)
      ].flatten.compact
    end

    # `type` may name one of the seven JSON Schema types, or name an array of them
    # meaning "any one of these". core's nullable fields are arrays —
    # `["string", "null"]` says the value is a string *or* is null — and reading
    # that array as a type name is what made this raise on core's very first
    # nullable field. An unknown name raises inside the array too, so
    # `["string", "date"]` fails rather than quietly accepting its string case.
    def type_violation(constraint, value, field)
      return unless constraint.key?("type")

      declared = constraint.fetch("type")
      types = declared.is_a?(Array) ? declared : [ declared ]
      unreadable = types - JSON_TYPES

      raise "this test does not understand type #{unreadable.inspect} on #{field}" if unreadable.any?
      raise "this test does not understand type #{declared.inspect} on #{field}" unless types.size == (declared.is_a?(Array) ? declared.size : 1)
      return if types.any? { |type| value_is_type?(type, value) }

      "#{field} is #{json_type_of(value)}, core says #{declared.inspect}"
    end

    def enum_violation(constraint, value, field)
      return unless constraint.key?("enum")
      return if constraint.fetch("enum").include?(value)

      "#{field} is #{value.inspect}, which is not one of #{constraint.fetch("enum").inspect}"
    end

    # `const` is how core says "this is the discriminator", and it is the only
    # constraint on `kind` — there is no `type` beside it, which is exactly the
    # shape that used to reach `fetch("type")` and raise a KeyError instead of
    # checking the value.
    def const_violation(constraint, value, field)
      return unless constraint.key?("const")
      return if constraint.fetch("const") == value

      "#{field} is #{value.inspect}, core says it is #{constraint.fetch("const").inspect}"
    end

    # Read as anchored to the whole string, never to a line. core writes `^…$`,
    # which in a Ruby `Regexp` anchors per line, and a value with an appended
    # second line would pass core's reading and fail this one. Narrower is the safe
    # direction, and it is the same narrowing the id-pattern test above asserts.
    def pattern_violation(constraint, value, field)
      return unless constraint.key?("pattern")
      return if value.is_a?(String) && whole_string(constraint.fetch("pattern")).match?(value)

      "#{field} is #{value.inspect}, core's pattern #{constraint.fetch("pattern").inspect} does not accept it"
    end

    def bound_violations(constraint, value, field)
      [
        length_violation(constraint, value, field, "minLength", :>=),
        length_violation(constraint, value, field, "maxLength", :<=),
        numeric_violation(constraint, value, field, "minimum", :>=),
        numeric_violation(constraint, value, field, "maximum", :<=)
      ].compact
    end

    # `minLength` constrains a string. `value.to_s.length` would let a null through
    # as a zero-length string, so the check only runs on the type the keyword can
    # actually constrain — a keyword applied to a value it cannot describe is
    # core's business, not a breach in the payload.
    def length_violation(constraint, value, field, keyword, direction)
      return unless constraint.key?(keyword) && value.is_a?(String)

      length = value.length
      return if direction == :>= ? length >= constraint.fetch(keyword) : length <= constraint.fetch(keyword)

      "#{field} is #{length} characters long, core says #{keyword} #{constraint.fetch(keyword)}"
    end

    def numeric_violation(constraint, value, field, keyword, direction)
      return unless constraint.key?(keyword) && value.is_a?(Numeric)

      return if direction == :>= ? value >= constraint.fetch(keyword) : value <= constraint.fetch(keyword)

      "#{field} is #{value.inspect}, core says #{keyword} #{constraint.fetch(keyword)}"
    end

    # `format` is an annotation in JSON Schema proper, so checking it is this
    # test's choice — but ignoring it would be worse, because `format: uuid` and
    # `format: date-time` are two of the ways core says "this value has a shape",
    # and skipping them leaves two thirds of a payload unchecked. A format this
    # does not implement raises rather than passing.
    def format_violation(constraint, value, field)
      return unless constraint.key?("format")
      return unless value.is_a?(String)

      format = constraint.fetch("format")
      check = UNDERSTOOD_FORMATS[format]

      raise "this test does not understand format #{format.inspect} on #{field}" if check.nil?
      return if check.call(value)

      "#{field} is #{value.inspect}, which is not a #{format}"
    end

    # core's D11, made machine-checked: `billing.payment.succeeded` has two shapes
    # and the schema says exactly one is present. A branch here is a list of
    # required fields, which is enough to say which shape is in hand, and a branch
    # carrying anything else raises rather than being read as a list it is not.
    def one_of_violations(constraint, value, field)
      return [] unless constraint.key?("oneOf")

      satisfied = constraint.fetch("oneOf").count { |branch|
        refuse_unknown_keywords(branch, field, ONE_OF_BRANCH_KEYWORDS)
        value.is_a?(Hash) && (branch["required"] || []).all? { |name| value.key?(name) }
      }

      return [] if satisfied == 1

      [ "#{field} satisfies #{satisfied} of core's #{constraint.fetch("oneOf").size} declared shapes, and exactly one of them" ]
    end

    # One type name, one question: is this value of that type?
    #
    # The `else` is a deliberate refusal and stays. It is what
    # UNDERSTOOD_KEYWORDS and the drift test are about — a validator that accepts
    # what it does not understand is worse than no validator, because it reports a
    # contract breach as clean — and the test above exercises this branch so it
    # cannot quietly become a permissive `rescue`.
    def value_is_type?(declared, value)
      case declared
      when "string" then value.is_a?(String)
      when "integer" then value.is_a?(Integer)
      when "number" then value.is_a?(Integer) || value.is_a?(Float)
      when "boolean" then value.equal?(true) || value.equal?(false)
      when "object" then value.is_a?(Hash)
      when "array" then value.is_a?(Array)
      when "null" then value.nil?
      else raise "this test does not understand type #{declared.inspect}"
      end
    end

    def json_type_of(value)
      case value
      when nil then "null"
      when true, false then "boolean"
      when Integer then "integer"
      when String then "string"
      when Hash then "object"
      when Array then "array"
      else value.class.name
      end
    end

    # --- core's schema, read from disk ---

    # Where core is, and the reason this file no longer answers that question
    # itself.
    #
    # This used to be a private method returning `Rails.root.join("..", "core")`,
    # which is correct for the main checkout and **nil from a worktree** — a
    # worktree has no `core` sibling, so every test here skipped and a whole
    # contract tier read as green having checked nothing. BRK-4R2: the worktree
    # reported 21 skips and a pass; the merged tree, on the same commit,
    # reported 0 skips and one failure. The `setup` skip below is untouched — a
    # repository with no core beside it really has no schemas to check against —
    # but the *resolution* is shared, in `TestSupport::CoreLocation`, and walks
    # the primary worktree through git so a worktree finds the same core its
    # main checkout does. One resolution for both of this file's readers.
    def core_path
      @core_path ||= core_location.path_for
    end

    # What the resolution tried, named in the skip so an operator is told where
    # to put core rather than told nothing.
    def default_core_path
      @default_core_path ||= core_location.searched.first
    end

    # Both readers answer "where is core" through this one module, so the two
    # cannot drift. The `nil` a reader would otherwise hand itself is handled
    # inside it — see `path_for`.
    def core_location
      TestSupport::CoreLocation
    end

    def schema
      return @schema if defined?(@schema)

      @schema = begin
        JSON.parse(File.read(File.join(core_path, ENVELOPE_SCHEMA)))
      rescue Errno::ENOENT, Errno::ENOTDIR
        nil
      end
    end

    def manifest
      @manifest ||= YAML.safe_load_file(Rails.root.join(MANIFEST), permitted_classes: [], aliases: false).transform_keys(&:to_s)
    end

    def payload_schema_for(event_type)
      @payload_schemas ||= {}
      @payload_schemas.fetch(event_type) do
        path = File.join(core_path, "schemas", "events", event_type.tr(".", "/") + ".schema.json")

        @payload_schemas[event_type] = begin
          JSON.parse(File.read(path))
        rescue Errno::ENOENT, Errno::ENOTDIR
          nil
        end
      end
    end

    # Every `pattern` core declares anywhere in a payload schema for a type this
    # build publishes, paired with every value this build emits at that place:
    # `[event_type, dotted_field, pattern, value]`.
    #
    # Anywhere, not just at the top level — `price.currency` and `amount.currency`
    # are constraints on money and deserve the same attention as `slug`, and a walk
    # that stopped at the top level would not have seen them.
    def core_patterns
      OutboxEvent::TYPES.flat_map { |event_type|
        schema = payload_schema_for(event_type)
        next [] if schema.nil?

        payloads_for(event_type).flat_map { |data| patterns_in(schema, data, event_type) }
      }
    end

    def patterns_in(constraint, value, event_type, prefix = nil, found = [])
      return found unless constraint["properties"].is_a?(Hash)

      constraint["properties"].each do |name, child|
        here = value.is_a?(Hash) ? value[name] : nil

        # Only a string can miss a pattern, and only a string this payload actually
        # carries is a gap anyone can act on. A null is not a wrong shape — it is
        # what `["string", "null"]` says the field is allowed to be, and the
        # payload test reports a missing or ill-typed value on its own. Recording
        # the other two here would put invented entries in a table whose whole
        # purpose is to be believed.
        found << [ event_type, dotted(prefix, name), child.fetch("pattern"), here ] if here.is_a?(String) && child.key?("pattern")

        patterns_in(child, here, event_type, dotted(prefix, name), found)
      end

      found
    end

    # The gaps `PENDING_ID_PATTERNS` is compared against, in exactly the shape the
    # table records: the event types whose declared patterns a value misses, and
    # for each the fields and the pattern core declared.
    #
    # Empty is the passing case, and it is empty because `core_patterns` walked
    # every pattern in every schema and matched none — not because the table had
    # nothing in it to iterate. The pattern is carried over from core rather than
    # compared against it, so a pattern core changes shows up as a different value
    # here and the table has to be updated to match: the both-directions property
    # the table was built for, without a loop that could run zero times.
    def id_pattern_gaps
      core_patterns.each_with_object({}) do |(event_type, field, pattern, value), gaps|
        next if value.is_a?(String) && whole_string(pattern).match?(value)

        ((gaps[event_type] ||= {})[field] = whole_string(pattern))
      end
    end

    # The pattern core declares at a dotted path, or a named raise. A schema that
    # dropped its pattern is a change to re-read, not a `Regexp.new(nil)` three
    # frames away from the comparison that wanted it.
    def declared_pattern(event_type, field)
      *parents, name = field.split(".")
      node = parents.reduce(payload_schema_for(event_type)) { |schema, part| schema.fetch("properties").fetch(part) }

      node.fetch("properties").fetch(name).fetch("pattern")
    rescue KeyError
      raise "core declares no pattern for #{event_type}.#{field}: re-read the schema before comparing grammars"
    end

    # A pattern read as anchored to the whole string rather than to a line.
    def whole_string(pattern)
      Regexp.new("\\A(?:#{pattern})\\z")
    end

    # Every keyword core uses anywhere in a payload schema for this service's
    # types: top level, inside `properties`, inside a nested object, inside a
    # `oneOf` branch. The drift test above is this list minus the vocabulary.
    def core_constraint_keywords
      OutboxEvent::TYPES.filter_map { |event_type| payload_schema_for(event_type) }
        .flat_map { |schema| keywords_in(schema) }
        .uniq
    end

    def keywords_in(node, found = [])
      case node
      when Hash
        node.each do |keyword, value|
          found << keyword

          case keyword
          when "properties" then value.each_value { |child| keywords_in(child, found) }
          when "oneOf" then value.each { |branch| keywords_in(branch, found) }
          end
        end
      when Array then node.each { |child| keywords_in(child, found) }
      end

      found
    end

    # core's catalog rows, as a set of published event types, keyed by publisher.
    def core_catalog
      return @core_catalog if defined?(@core_catalog)

      text = begin
        File.read(File.join(core_path, "docs", "event-naming.md"))
      rescue Errno::ENOENT, Errno::ENOTDIR
        return @core_catalog = nil
      end

      section = text[/^## Catalog.*?(?=^## )/m]
      billing = section[/^### billing.*?(?=^### |\z)/m]

      @core_catalog = billing.to_s.scan(/^\|\s*`([a-z][a-z0-9_.]+)`\s*\|/).flatten
    end

    # --- the checks, one per constraint core states ---

    # Two patterns are the same grammar if they accept the same strings, so that
    # is what is compared.
    #
    # The obvious alternative — comparing `Regexp#source` against core's pattern
    # string — is what this test used to do, and it is wrong twice over. Ruby's
    # regexp optimiser rewrites `{1,2}` and friends in a way that is not stable
    # across processes, so the same constant can report two different sources on
    # two different runs: a comparison on the text passes once and fails
    # forever after, with nothing changed in between. And even a stable
    # comparison would only prove the two texts are alike, not that they accept
    # the same language. A corpus does prove that.
    GRAMMAR_CORPUS = [
      # What this service emits. Kept as the full list rather than one example:
      # a corpus is only evidence about the strings in it.
      "billing.customer.created",
      "billing.payment.failed",
      "billing.payment.succeeded",
      "billing.plan.created",
      "billing.plan.updated",
      "billing.subscription.canceled",
      "billing.subscription.started",
      "billing.subscription.updated",
      # The other legal shape: two segments.
      "customer.created",
      # A uuid, which is what a subject is in practice.
      "11111111-1111-4111-8111-111111111111",
      "usr_01J9Z8QK5M4N7P2R3T6V8W9X0A",
      # What a webhook's subject is, before this service has its own ids for
      # subscriptions: the processor's.
      "sub_1PZQaBcDeFgHiJkLmNoPqR1",
      # Neighbouring cases, where a grammar difference would show up.
      "identity.api_key.created",
      "billing",
      "customer",
      "",
      "Billing.customer.created",
      "billing.Customer.created",
      "1billing.customer.created",
      "billing..created",
      "billing.customer.",
      ".billing.customer",
      "billing.customer.created.",
      "billing.customer.created.extra",
      "billing-customer.created",
      "billing_customer.created",
      "billing.customer.created ",
      " billing.customer.created",
      "user@example.com",
      "cus_1",
      "-cus_1",
      "_cus_1",
      "cus 1",
      "cus/1",
      "cus:1",
      "cus@1"
    ].freeze

    def assert_same_grammar(core_pattern, ours, corpus = GRAMMAR_CORPUS)
      theirs = Regexp.new(core_pattern)

      disagreements = corpus.reject { |candidate| theirs.match?(candidate) == ours.match?(candidate) }

      assert_empty disagreements, "core and this service disagree about: #{disagreements.inspect}"
    end

    # A property-by-property check, not a JSON Schema engine: a dependency that
    # can validate a document is a dependency this service does not have, and
    # the two payload schemas in core are flat objects of typed scalars. The
    # constraints actually used are asserted, so a schema that starts using
    # something this does not understand fails loudly instead of passing.
    def assert_valid_envelope(envelope)
      properties = schema.fetch("properties")

      # core's `required` is the floor, not the whole set: `subject` is a
      # DECISION NEEDED in core's event-naming.md (D2) and its schema file
      # currently leaves it out of `required` while still constraining it. So
      # the two checks are "everything required is there" and "nothing outside
      # the declared properties is there" — which is what
      # `additionalProperties: false` actually says.
      assert_empty schema.fetch("required") - envelope.keys, "envelope is missing a required attribute"
      assert_empty envelope.keys - properties.keys, "additionalProperties is false in core"

      assert_equal properties.dig("specversion", "const"), envelope.fetch("specversion")
      assert_match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i, envelope.fetch("id"))
      assert_within(resolve(properties.fetch("type")), envelope.fetch("type"))
      assert_within(resolve(properties.fetch("source")), envelope.fetch("source"))
      assert_within(properties.fetch("subject"), envelope.fetch("subject"))
      assert_kind_of Hash, envelope.fetch("data")
      assert_time_is_rfc3339(envelope.fetch("time"))
    end

    # core states `type` and `source` as a `$ref` into `$defs`, so the
    # constraints — minLength, maxLength, pattern — are not on the property
    # itself. Following the ref is what makes this a check against core's
    # grammar rather than against a paraphrase of it.
    def resolve(constraint)
      return constraint unless constraint.key?("$ref")

      constraint.fetch("$ref").delete_prefix("#/").split("/").reduce(schema) { |node, key| node.fetch(key) }
    end

    def assert_within(constraint, value)
      assert_kind_of String, value
      assert_operator value.length, :>=, constraint.fetch("minLength")
      assert_operator value.length, :<=, constraint.fetch("maxLength")
      assert_match(/#{constraint.fetch("pattern")}/, value, "#{value.inspect} must match core's pattern")
    end

    def assert_time_is_rfc3339(value)
      assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, value)
    end
end
