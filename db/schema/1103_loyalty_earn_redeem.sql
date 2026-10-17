-- =====================================================================
-- Masslak - 1103: loyalty points are earned and redeemed (a gap found by the review of the use cases, October 2026)
--
-- The programme, its tiers, rules, accounts and the append-only points ledger existed and the platform could manage
-- them, but no point was ever earned or spent. Three functions now move points, each idempotent:
--   * pricing.earn_points_for_trip, called when the carrier completes a trip: each completed booking made by a person
--     (not an agency) earns, for every active EARN rule of an active programme in the booking's currency, the rule's
--     points on what was travelled (the tickets that boarded). formula = {"per_amount": <minor units>, "points": n,
--     "multiplier": m}; condition may hold "min_amount" (minor units) and "company_ids" (the carriers it applies to).
--     Points expire after the programme's expiry_months. The account's tier follows the points earned so far.
--   * pricing.redeem_points: the member turns points into wallet credit at the programme's point value, at least the
--     BURN rule's min_points and in its step. The application posts the money in the same transaction, from the
--     platform's loyalty expense wallet (added here, one per currency) to the member's wallet, so the money ledger
--     and the points ledger move together.
--   * pricing.expire_points, run daily by the worker: points earned more than expiry_months ago and not yet spent
--     (redemptions use the oldest points first) leave the balance.
-- pricing.points_liability keeps per month and issuer the value issued, redeemed and expired (issuer empty: the
-- platform; the carrier for CARRIER-funded rules, for settlement).
-- =====================================================================

-- the platform's loyalty expense wallet: debited by every redemption, so its (negative) balance is the cost of rewards
INSERT INTO fin.wallet (owner_party_id, wallet_type, label, currency, allow_negative, balance_mode)
SELECT w.owner_party_id, 'EXPENSE', 'Loyalty rewards', w.currency, true, 'DEFERRED'
  FROM fin.wallet w JOIN iam.party p ON p.id = w.owner_party_id
 WHERE p.legal_name = 'Masslak Platform' AND p.party_type = 'COMPANY' AND w.wallet_type = 'PLATFORM'
ON CONFLICT (owner_party_id, wallet_type, currency) WHERE owner_party_id IS NOT NULL DO NOTHING;

CREATE OR REPLACE FUNCTION pricing.add_liability(p_program bigint, p_issuer bigint, p_kind text, p_value bigint) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_period daterange := daterange(date_trunc('month', now())::date, (date_trunc('month', now()) + interval '1 month')::date);
BEGIN
  INSERT INTO pricing.points_liability (program_id, issuer_party_id, period, issued, redeemed, expired)
  VALUES (p_program, p_issuer, v_period, CASE WHEN p_kind = 'ISSUED' THEN p_value ELSE 0 END,
          CASE WHEN p_kind = 'REDEEMED' THEN p_value ELSE 0 END, CASE WHEN p_kind = 'EXPIRED' THEN p_value ELSE 0 END)
  ON CONFLICT (program_id, issuer_party_id, period) DO UPDATE
     SET issued = pricing.points_liability.issued + EXCLUDED.issued,
         redeemed = pricing.points_liability.redeemed + EXCLUDED.redeemed,
         expired = pricing.points_liability.expired + EXCLUDED.expired;
END $$;
REVOKE ALL ON FUNCTION pricing.add_liability(bigint, bigint, text, bigint) FROM PUBLIC;
COMMENT ON FUNCTION pricing.add_liability IS 'Adds to the month''s points liability of a programme and issuer (1103)';

CREATE OR REPLACE FUNCTION pricing.earn_points_for_trip(p_trip_id bigint) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  v_trip record;
  v_b record;
  v_r record;
  v_account bigint;
  v_points bigint;
  v_ledger bigint;
  v_awarded integer := 0;
  v_total bigint := 0;
  v_earned bigint;
BEGIN
  SELECT id, company_id, trip_no, status INTO v_trip FROM ops.trip WHERE id = p_trip_id;
  IF v_trip.status IS DISTINCT FROM 'COMPLETED' THEN
    RETURN jsonb_build_object('bookings', 0, 'points', 0);
  END IF;
  FOR v_b IN
    SELECT b.id, b.booker_party_id, b.booker_user_id, b.currency,
           (SELECT coalesce(sum(k.total_amount), 0) FROM sales.ticket k WHERE k.booking_id = b.id AND k.status = 'BOARDED') AS travelled
      FROM sales.booking b JOIN iam.party p ON p.id = b.booker_party_id
     WHERE b.trip_id = p_trip_id AND b.status = 'COMPLETED' AND b.agency_id IS NULL AND p.party_type = 'PERSON'
  LOOP
    v_earned := 0;
    FOR v_r IN
      SELECT r.id AS rule_id, r.formula, r.condition, r.funded_by, g.id AS program_id, g.point_value, g.expiry_months
        FROM pricing.loyalty_rule r JOIN pricing.loyalty_program g ON g.id = r.program_id
       WHERE g.status = 'ACTIVE' AND g.currency = v_b.currency AND r.kind = 'EARN' AND r.active AND r.valid @> now()
         AND v_b.travelled >= coalesce((r.condition ->> 'min_amount')::bigint, 0)
         AND (NOT r.condition ? 'company_ids' OR r.condition -> 'company_ids' @> to_jsonb(v_trip.company_id))
       ORDER BY r.id
    LOOP
      v_points := floor(v_b.travelled / greatest(coalesce((v_r.formula ->> 'per_amount')::bigint, 1), 1))
                  * coalesce((v_r.formula ->> 'points')::bigint, 0) * coalesce((v_r.formula ->> 'multiplier')::numeric, 1);
      CONTINUE WHEN v_points <= 0;
      INSERT INTO pricing.points_account (program_id, party_id) VALUES (v_r.program_id, v_b.booker_party_id)
      ON CONFLICT (program_id, party_id) DO NOTHING;
      SELECT id INTO v_account FROM pricing.points_account
       WHERE program_id = v_r.program_id AND party_id = v_b.booker_party_id AND status = 'ACTIVE';
      CONTINUE WHEN v_account IS NULL;                      -- a frozen or closed account earns nothing
      INSERT INTO pricing.points_ledger (account_id, txn_type, points, booking_id, rule_id, funded_by, idempotency_key, expires_at)
      VALUES (v_account, 'EARN', v_points, v_b.id, v_r.rule_id, v_r.funded_by, format('earn:%s:%s', v_b.id, v_r.rule_id),
              now() + make_interval(months => v_r.expiry_months))
      ON CONFLICT (idempotency_key) DO NOTHING RETURNING id INTO v_ledger;
      CONTINUE WHEN v_ledger IS NULL;                       -- already earned
      UPDATE pricing.points_account a
         SET balance = a.balance + v_points,
             tier_id = (SELECT t.id FROM pricing.loyalty_tier t WHERE t.program_id = a.program_id
                           AND t.min_points <= (SELECT coalesce(sum(l.points), 0) FROM pricing.points_ledger l
                                                 WHERE l.account_id = a.id AND l.txn_type = 'EARN')
                         ORDER BY t.min_points DESC LIMIT 1)
       WHERE a.id = v_account;
      PERFORM pricing.add_liability(v_r.program_id, CASE WHEN v_r.funded_by = 'CARRIER' THEN v_trip.company_id END, 'ISSUED',
                                    v_points * v_r.point_value);
      v_earned := v_earned + v_points;
    END LOOP;
    IF v_earned > 0 THEN
      v_awarded := v_awarded + 1;
      v_total := v_total + v_earned;
      INSERT INTO sys.outbox_event (event_type, aggregate_type, aggregate_id, company_id, payload)
      VALUES ('points.earned', 'booking', v_b.id, v_trip.company_id,
              jsonb_build_object('points', v_earned, 'trip_no', v_trip.trip_no, 'booker_user_id', v_b.booker_user_id,
                                 'balance', (SELECT sum(balance) FROM pricing.points_account WHERE party_id = v_b.booker_party_id)));
    END IF;
  END LOOP;
  RETURN jsonb_build_object('bookings', v_awarded, 'points', v_total);
END $$;
REVOKE ALL ON FUNCTION pricing.earn_points_for_trip(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pricing.earn_points_for_trip(bigint) TO masslak_app;
COMMENT ON FUNCTION pricing.earn_points_for_trip IS 'Points for the boarded tickets of a completed trip''s bookings made by people, per active EARN rule; idempotent (1103)';

CREATE OR REPLACE FUNCTION pricing.redeem_points(p_party_id bigint, p_points bigint, p_key text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  v_a record;
  v_min bigint;
  v_step bigint;
  v_ledger bigint;
BEGIN
  IF p_party_id IS DISTINCT FROM sys.ctx_party_id() AND NOT sys.ctx_is_platform() THEN
    RAISE EXCEPTION 'POINTS_NOT_YOURS: points are redeemed by their member' USING ERRCODE = 'P0001';
  END IF;
  SELECT a.id, a.balance, a.status, g.id AS program_id, g.point_value, g.currency, g.status AS program_status INTO v_a
    FROM pricing.points_account a JOIN pricing.loyalty_program g ON g.id = a.program_id
   WHERE a.party_id = p_party_id ORDER BY (g.status = 'ACTIVE') DESC, a.id LIMIT 1 FOR UPDATE OF a;
  IF v_a.id IS NULL OR v_a.status <> 'ACTIVE' OR v_a.program_status <> 'ACTIVE' THEN
    RAISE EXCEPTION 'POINTS_NOT_AVAILABLE: there is no active points account to redeem from' USING ERRCODE = 'P0001';
  END IF;
  SELECT id INTO v_ledger FROM pricing.points_ledger WHERE idempotency_key = p_key;
  IF v_ledger IS NOT NULL THEN                              -- the same request again: nothing more is taken
    RETURN jsonb_build_object('ledger_id', v_ledger, 'points', p_points, 'value', p_points * v_a.point_value,
                              'currency', v_a.currency, 'replayed', true);
  END IF;
  SELECT coalesce((formula ->> 'min_points')::bigint, 1), coalesce((formula ->> 'step')::bigint, 1) INTO v_min, v_step
    FROM pricing.loyalty_rule WHERE program_id = v_a.program_id AND kind = 'BURN' AND active AND valid @> now()
   ORDER BY id DESC LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'POINTS_NOT_REDEEMABLE: the programme takes no redemptions now' USING ERRCODE = 'P0001';
  END IF;
  IF p_points < v_min OR p_points % greatest(v_step, 1) <> 0 THEN
    RAISE EXCEPTION 'POINTS_BAD_AMOUNT: redeem at least % points, in steps of %', v_min, v_step USING ERRCODE = 'P0001';
  END IF;
  IF p_points > v_a.balance THEN
    RAISE EXCEPTION 'POINTS_INSUFFICIENT: the balance is % points', v_a.balance USING ERRCODE = 'P0001';
  END IF;
  INSERT INTO pricing.points_ledger (account_id, txn_type, points, funded_by, idempotency_key)
  VALUES (v_a.id, 'REDEEM', -p_points, 'PLATFORM', p_key) RETURNING id INTO v_ledger;
  UPDATE pricing.points_account SET balance = balance - p_points WHERE id = v_a.id;
  PERFORM pricing.add_liability(v_a.program_id, NULL, 'REDEEMED', p_points * v_a.point_value);
  RETURN jsonb_build_object('ledger_id', v_ledger, 'points', p_points, 'value', p_points * v_a.point_value,
                            'currency', v_a.currency, 'replayed', false, 'balance', v_a.balance - p_points);
END $$;
REVOKE ALL ON FUNCTION pricing.redeem_points(bigint, bigint, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pricing.redeem_points(bigint, bigint, text) TO masslak_app;
COMMENT ON FUNCTION pricing.redeem_points IS 'The member spends points for wallet credit at the point value, per the BURN rule; the caller posts the money (1103)';

CREATE OR REPLACE FUNCTION pricing.expire_points() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  v_a record;
  v_points bigint;
  v_accounts integer := 0;
  v_total bigint := 0;
BEGIN
  FOR v_a IN
    SELECT a.id, a.balance, a.program_id, g.point_value,
           (SELECT coalesce(sum(points), 0) FROM pricing.points_ledger l WHERE l.account_id = a.id AND l.txn_type = 'EARN'
               AND l.expires_at <= now()) AS due,
           (SELECT coalesce(-sum(points), 0) FROM pricing.points_ledger l WHERE l.account_id = a.id
               AND l.txn_type IN ('REDEEM','EXPIRE','REVERSE') AND l.points < 0) AS used
      FROM pricing.points_account a JOIN pricing.loyalty_program g ON g.id = a.program_id
     WHERE a.balance > 0 AND EXISTS (SELECT 1 FROM pricing.points_ledger l WHERE l.account_id = a.id AND l.txn_type = 'EARN'
                                       AND l.expires_at <= now())
     FOR UPDATE OF a
  LOOP
    -- points spent so far count against the oldest earnings first; what is past expiry and not spent leaves
    v_points := least(greatest(v_a.due - v_a.used, 0), v_a.balance);
    CONTINUE WHEN v_points <= 0;
    INSERT INTO pricing.points_ledger (account_id, txn_type, points, idempotency_key)
    VALUES (v_a.id, 'EXPIRE', -v_points, format('expire:%s:%s', v_a.id, v_a.due))
    ON CONFLICT (idempotency_key) DO NOTHING;
    CONTINUE WHEN NOT FOUND;
    UPDATE pricing.points_account SET balance = balance - v_points WHERE id = v_a.id;
    PERFORM pricing.add_liability(v_a.program_id, NULL, 'EXPIRED', v_points * v_a.point_value);
    v_accounts := v_accounts + 1;
    v_total := v_total + v_points;
  END LOOP;
  RETURN jsonb_build_object('accounts', v_accounts, 'points', v_total);
END $$;
REVOKE ALL ON FUNCTION pricing.expire_points() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pricing.expire_points() TO masslak_app;
COMMENT ON FUNCTION pricing.expire_points IS 'Daily: points past expiry and not spent (oldest spent first) leave the balance (1103)';

-- a redemption's money transaction names the points ledger row it pays for
UPDATE sys.polymorphic_reference SET targets = targets || '{"points_ledger": "pricing.points_ledger"}'::jsonb
 WHERE table_name = 'fin.ledger_txn' AND NOT targets ? 'points_ledger';
