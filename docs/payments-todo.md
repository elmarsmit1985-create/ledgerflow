# Payments hookup (on hold, to be completed)

Status as of 4 Nov 2026: **paused**. Pick up from "Next steps" below.

## Already done

- Free trial is **one month** for every new business (`businesses.trial_ends`, default now + 1 month).
- When the trial and the paid period (`businesses.paid_until`) have both passed, the business is fully locked:
  - The database blocks all records, documents, payroll, user profiles and invites.
  - The app shows a locked screen and clears the books stored on the device.
- Live in Supabase: migrations `20261104_subscription_lock.sql` and `20261104_trial_one_month.sql`.
- App side: PR #12 (branch `feature/subscription-lock`), waiting to be merged.
- ECS Africa is `always_on` and never locks.
- `public.set_paid_until(business, until)` exists for the payment process to call. It is service role only.
- Until payments are connected, renewals are manual: extend `paid_until` with the SQL in the README.

## Decisions made

- **Gateway:** PayFast. It charges the card in rand and pays out in rand.
- **South African customers:**
  - Normal PayFast monthly subscription in rand: Entry R200, Full suite R650, Full custom R950.
  - A yearly option ("2 months free": R2,000 / R6,500 / R9,500) was discussed but not decided.
- **International customers:**
  - The price is fixed in their own currency, e.g. $35/month.
  - They must NOT be billed the same number in rand. PayFast's own subscriptions do this: $109 becomes about R2,000 the first month, then R109 after.
  - Approach: PayFast **tokenization / ad hoc charges**.
    1. The first checkout through PayFast saves the card as a token. Multi-Currency Pricing shows the buyer their own currency at checkout.
    2. A monthly scheduled job in Supabase (pg_cron plus an Edge Function):
       - gets that day's exchange rate;
       - works out the rand amount (customer price × rate);
       - charges the token through PayFast's ad hoc API.
    3. PayFast's payment notification (ITN) goes to an Edge Function, which checks the signature and passphrase and calls `set_paid_until` to add one month.
    4. A failed charge means `paid_until` is not extended, and the business locks at the end of the paid month.
  - The customer's statement will be close to, but not exactly, their price, because their bank converts from rand and may add a foreign transaction fee.
  - If an exact amount in their own currency is ever required, use PayPal subscriptions or Paddle instead for international customers.
- **PayFast fees:**
  - No setup or monthly fee.
  - Card payments: 3.2% + R2 per payment (ex VAT).
  - Payouts: R8.70 each.
  - Multi-Currency Pricing does not support AMEX.

## Next steps

1. **Elmar:**
   - Open the PayFast merchant account (ECS Africa / Kontivo).
   - Ask PayFast to enable tokenization / ad hoc payments.
   - Optionally, confirm in writing with PayFast how foreign-currency subscriptions behave.
2. **Elmar:** send the merchant ID, merchant key and passphrase. Store them as Supabase Edge Function secrets, never in `index.html`.
3. **Build:**
   - A plan picker with a "Subscribe" button for each plan on the locked screen and in Settings.
   - Store each customer's billing currency and price, and the PayFast token.
   - An ITN handler Edge Function: verify the payment, then call `set_paid_until`.
   - A monthly billing job for international customers: exchange rate, then the rand amount, then the ad hoc charge.
   - Emails or notices for a failed payment and for an upcoming renewal.
4. Test end to end in the PayFast sandbox before going live.
5. Merge PR #12 if it isn't merged already.
