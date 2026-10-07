# Event contract for webhook receivers

Masslak sends business events (bookings, payments, manifests, notices to authorities) to the endpoints a partner registers.
Events come from the transactional outbox: an event exists only if the change that caused it was committed.

## Envelope

```json
{
  "id": "6f1c…",                 // event id, unique forever
  "type": "booking.confirmed",
  "created_at": "2026-10-07T09:15:02+00:00",
  "api_version": "v1",
  "schema_version": 1,           // version of this event type's "data" shape
  "correlation_id": "2b9e…",     // the request that caused it (null for scheduled work)
  "aggregate": "booking",        // the kind of record the event is about
  "sequence": 3,                 // its order among that record's events: 1, 2, 3 ...
  "data": { … }
}
```

Each request carries a signature header:

```
X-Masslak-Signature: t=<unix seconds>,v1=<hex HMAC-SHA256(secret, "<t>." + body)>
```

Personal fields are removed from `data` unless the endpoint was registered with personal data enabled.

## Guarantees

- **At least once.** A delivery is retried after 1, 2, 4 … 64 minutes, eight times at most, then marked DEAD and shown in
  the integration console. The same event can therefore arrive more than once, for example after a timeout on your side.
- **No global order.** Events of different records arrive in any order. Within one record, `sequence` gives the order.
- **Stable ids.** A retry sends the same `id` and the same body.
- **HTTPS only**, to a public address, with the certificate checked. No redirect is followed: a 3xx counts as a failure.

## What a receiver must do

1. **Check the signature**, and reject a timestamp older than five minutes (replay).
2. **Answer 2xx quickly**, then process. Anything else, or no answer within 10 seconds, is retried.
3. **Apply each `id` once.** Keep the ids you have applied (an inbox table with a unique key) and ignore a repeat. This
   matters most for money: a refund or payment notice applied twice is a real loss.
4. **Respect `sequence` per record.** If you receive sequence 3 before 2, hold it or fetch the record's current state
   from the API (`GET /api/v1/...`). Never move a record's state backwards on an older sequence.
5. **Read `schema_version`.** A new version of an event type is announced in advance. Fields are only ever added within a
   version.

## Replays

- **Who can retry:** the partner can retry a FAILED or DEAD delivery from the integration console, or through
  `POST /api/v1/webhooks/deliveries/{uid}/retry`. Each retry is recorded in the activity log with who asked for it.
- **What is sent:** a retry sends the same event `id` and body.
- **Your side:** the receiver's inbox makes any replay harmless.

## Inbound notices from payment providers

Notices a payment provider sends to Masslak are de-duplicated the same way: one row per provider and provider event id
(`fin.payment_notification`). Payments and refunds also carry idempotency keys, so a retried request never charges or
refunds twice.
