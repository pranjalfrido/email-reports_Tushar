-- CLICKPOST PENDENCY — every open shipment, bucketed by where it is stuck, with ageing.
-- Used by email-reports/email-clickpost-pendency.mjs.
--
-- Source: production.Clickpost_Shipment_Tracking_Report (one row per AWB, all columns STRING).
-- Grain:  one row per open AWB.
-- Window: AWBs CREATED in the last 45 days (rolling, IST). Older "open" rows are almost all
--         dead records that never received a terminal status; left in, they would swamp the
--         report. The 30+ day bucket still catches the real laggards.
--
--         The window is on created_at, NOT order_date: Reverse rows carry no order_date
--         (75,612 of 75,882 since Aug-26 are blank), so an order_date filter silently drops
--         almost every RVP. For Forward the two agree closely (AWB created a median 1 day
--         after the order), so the forward numbers barely move.
--
-- ===================== PENDENCY TYPES =====================
--   1 Pickup pending           Forward, not yet picked up
--                              (OrderPlaced, Awb Registered, PickupPending, OutForPickup, PickupFailed, RiderAllocationAwaited)
--                              ageing from AWB creation
--   2 Hub scan pending         Forward, status PickedUp — collected but never in-scanned at a hub
--                              ageing from pickup
--   3 Delivery pending         Forward, picked up and moving, not delivered or RTO'd
--                              ageing from pickup; also days since last scan and days past
--                              the courier's EDD
--   4 RTO delivery pending     Forward, any RTO-* status except RTO-Delivered
--                              ageing from RTO mark date (last scan if missing)
--   5 RVP pickup pending       Reverse, not yet picked up from the customer
--                              ageing from AWB creation
--   6 RVP delivery pending     Reverse, picked up but not yet delivered back to the warehouse
--                              ageing from pickup
--   7 Unmapped status          any status not on one of the explicit lists below - i.e. a status
--                              Clickpost has introduced since this was written. Flagged in the
--                              email so it gets mapped, never silently counted as in transit.
--
--   EDD breached (a view, not a pendency type): the subset of 3 already past the courier's EDD,
--   aged by days past EDD in edd_breach_bucket (1, 2-3, 4-7, 8-15, 16-30, 30+ d).
--
-- Terminal statuses (never pending): Delivered, RTO-Delivered, Cancelled, Lost, Damaged, and
-- ReShippedOnNewWaybill (the parcel continues under a new AWB, which is tracked on its own row).
-- Everything else is open and sits on one of the explicit lists. RiderAllocationAwaited is a
-- pre-pickup status, so it counts as pickup pending alongside the five below.
--
-- ===================== TIME ZONES =====================
-- pickup_date, latest_timestamp and destination_hub_in_scan_time are IST. created_at and
-- updated_at are UTC (updated_at runs ~5.5 h behind latest_timestamp on the same scan), so
-- created_at is converted before taking its IST date.
--
-- ===================== AGEING BUCKETS =====================
--   0-1 d, 2-3 d, 4-7 d, 8-15 d, 16-30 d, 30+ d

WITH cp AS (
  SELECT *
  FROM `frido-429506.production.Clickpost_Shipment_Tracking_Report`
  WHERE DATE(DATETIME(SAFE_CAST(created_at AS TIMESTAMP), 'Asia/Kolkata'))
        >= DATE_SUB(CURRENT_DATE('Asia/Kolkata'), INTERVAL 45 DAY)
    AND clickpost_unified_status NOT IN ('Delivered', 'RTO-Delivered', 'Cancelled', 'Lost', 'Damaged', 'ReShippedOnNewWaybill')
  -- One row per AWB; the table carries a stray duplicate or two.
  QUALIFY ROW_NUMBER() OVER (PARTITION BY awb ORDER BY updated_at DESC) = 1
),

typed AS (
  SELECT
    cp.*,
    DATE(DATETIME(SAFE_CAST(created_at AS TIMESTAMP), 'Asia/Kolkata'))         AS created_date_ist,
    SAFE_CAST(NULLIF(pickup_date, '') AS DATETIME)                             AS pickup_dt,
    SAFE_CAST(NULLIF(latest_timestamp, '') AS DATETIME)                        AS last_scan_dt,
    SAFE_CAST(SUBSTR(NULLIF(expected_delivery_date_by_courier_partner, ''), 1, 10) AS DATE) AS edd,
    SAFE_CAST(SUBSTR(NULLIF(rto_mark_date, ''), 1, 10) AS DATE)                AS rto_mark_dt,
    -- Every bucket is an EXPLICIT status list. A status Clickpost introduces later matches none
    -- of them and lands in '7. Unmapped status', which the email flags — rather than being
    -- silently counted as in transit (a new terminal status would otherwise inflate pendency).
    -- Status alone decides: a PickedUp row with a blank pickup_date has still been collected,
    -- and its ageing falls back to the creation date.
    CASE
      WHEN clickpost_unified_status IN ('OrderPlaced', 'Awb Registered', 'PickupPending', 'OutForPickup',
                                        'PickupFailed', 'RiderAllocationAwaited')
        THEN IF(shipment_type = 'Reverse', '5. RVP pickup pending', '1. Pickup pending')
      WHEN clickpost_unified_status IN ('PickedUp', 'OriginCityIn', 'OriginCityOut', 'InTransit',
                                        'DestinationHubIn', 'OutForDelivery', 'FailedDelivery',
                                        'ShipmentDelayed', 'ShipmentHeld', 'ContactCustomerCare',
                                        'NotServiceable', 'NoStatusExist')
        THEN CASE
               WHEN shipment_type = 'Reverse'               THEN '6. RVP delivery pending'
               WHEN clickpost_unified_status = 'PickedUp'   THEN '2. Hub scan pending'
               ELSE '3. Delivery pending'
             END
      WHEN clickpost_unified_status IN ('RTO-Requested', 'RTO-Marked', 'RTO-InTransit', 'RTO-OutForDelivery',
                                        'RTO-Failed', 'RTO-ShipmentDelay', 'RTO-ContactCustomerCare')
        -- A reverse leg showing RTO is still on its way back, so it stays an RVP.
        THEN IF(shipment_type = 'Reverse', '6. RVP delivery pending', '4. RTO delivery pending')
      ELSE '7. Unmapped status'
    END AS pendency_type
  FROM cp
),

aged AS (
  SELECT
    *,
    DATE_DIFF(CURRENT_DATE('Asia/Kolkata'),
      CASE
        WHEN pendency_type IN ('1. Pickup pending', '5. RVP pickup pending') THEN created_date_ist
        WHEN pendency_type = '4. RTO delivery pending' THEN COALESCE(rto_mark_dt, DATE(last_scan_dt))
        ELSE COALESCE(DATE(pickup_dt), created_date_ist)
      END, DAY) AS ageing_days
  FROM typed
),

-- Every other reverse AWB raised for the same order (any date, any status). Shows when an RVP
-- has been re-raised: if another AWB for the order is already picked up or delivered, this
-- one is probably a dead duplicate the courier never cancelled. Not excluded automatically -
-- a multi-item order can legitimately have one item's RVP delivered and another's pending.
rev_all AS (
  SELECT awb, order_id, clickpost_unified_status AS s, created_at
  FROM `frido-429506.production.Clickpost_Shipment_Tracking_Report`
  WHERE shipment_type = 'Reverse'
    AND order_id IN (SELECT order_id FROM aged WHERE shipment_type = 'Reverse')
  QUALIFY ROW_NUMBER() OVER (PARTITION BY awb ORDER BY updated_at DESC) = 1
),
other_rvp AS (
  SELECT a.awb,
         STRING_AGG(CONCAT(r.awb, ' ', r.s), '; ' ORDER BY r.created_at DESC LIMIT 5) AS other_rvp_for_order,
         COUNTIF(r.s IN ('PickedUp', 'InTransit', 'OutForDelivery', 'DestinationHubIn', 'Delivered')) > 0
                                                                                AS other_rvp_collected
  FROM aged a
  JOIN rev_all r ON r.order_id = a.order_id AND r.awb <> a.awb
  WHERE a.shipment_type = 'Reverse'
  GROUP BY a.awb
)

SELECT
  pendency_type,
  courier_partner                                             AS courier,
  ageing_days,
  CASE
    WHEN ageing_days IS NULL THEN 'unknown'
    WHEN ageing_days <= 1  THEN '0-1 d'
    WHEN ageing_days <= 3  THEN '2-3 d'
    WHEN ageing_days <= 7  THEN '4-7 d'
    WHEN ageing_days <= 15 THEN '8-15 d'
    WHEN ageing_days <= 30 THEN '16-30 d'
    ELSE '30+ d'
  END                                                         AS ageing_bucket,

  -- ---- shipment ----
  awb,
  order_id,
  reference_number,
  channel_name,
  clickpost_unified_status                                    AS status,
  -- Clickpost's own "stuck in lifecycle" flag, as sent (True/False).
  is_shipment_stuck_in_lifecycle                              AS cp_stuck_flag,
  payment_mode,
  SAFE_CAST(NULLIF(cod_value, '') AS FLOAT64)                 AS cod_value,
  SAFE_CAST(NULLIF(invoice_value, '') AS FLOAT64)             AS invoice_value,
  product_sku_code                                            AS sku,
  items,
  SAFE_CAST(NULLIF(items_quantity, '') AS INT64)              AS qty,
  zone_by_frido                                               AS zone,

  -- ---- dates ----
  SAFE_CAST(SUBSTR(order_date, 1, 10) AS DATE)                AS order_date,
  created_date_ist                                            AS awb_created_date,
  pickup_dt                                                   AS pickup_time,
  last_scan_dt                                                AS last_scan_time,
  DATE_DIFF(CURRENT_DATE('Asia/Kolkata'), DATE(last_scan_dt), DAY) AS days_since_last_scan,
  edd                                                         AS courier_edd,
  -- Positive = EDD already missed by that many days. Only meaningful while the parcel is
  -- still heading to the customer, so it is left NULL on RTO and reverse legs.
  IF(pendency_type = '3. Delivery pending',
     DATE_DIFF(CURRENT_DATE('Asia/Kolkata'), edd, DAY), NULL) AS days_past_edd,
  -- EDD-breached view: delivery pendency already past the courier's EDD, aged by days past EDD.
  -- NULL when the EDD is still ahead (or today), or the courier gave none.
  CASE
    WHEN pendency_type <> '3. Delivery pending' OR edd IS NULL
      OR DATE_DIFF(CURRENT_DATE('Asia/Kolkata'), edd, DAY) <= 0 THEN NULL
    WHEN DATE_DIFF(CURRENT_DATE('Asia/Kolkata'), edd, DAY) = 1  THEN '1 d'
    WHEN DATE_DIFF(CURRENT_DATE('Asia/Kolkata'), edd, DAY) <= 3  THEN '2-3 d'
    WHEN DATE_DIFF(CURRENT_DATE('Asia/Kolkata'), edd, DAY) <= 7  THEN '4-7 d'
    WHEN DATE_DIFF(CURRENT_DATE('Asia/Kolkata'), edd, DAY) <= 15 THEN '8-15 d'
    WHEN DATE_DIFF(CURRENT_DATE('Asia/Kolkata'), edd, DAY) <= 30 THEN '16-30 d'
    ELSE '30+ d'
  END                                                         AS edd_breach_bucket,
  SAFE_CAST(NULLIF(destination_hub_in_scan_time, '') AS DATETIME) AS dest_hub_inscan_time,
  rto_mark_dt                                                 AS rto_mark_date,
  NULLIF(rto_awb, '')                                         AS rto_awb,

  -- ---- pickup attempts (forward pickup and RVP) ----
  -- Clickpost never fills the failed-PICKUP reason/remark columns (0% populated); the
  -- courier's reason for a failed pickup arrives in latest_remark instead.
  SAFE_CAST(NULLIF(out_for_pickup_attempts, '') AS INT64)     AS pickup_attempts,
  SAFE_CAST(NULLIF(out_for_pickup_1st_attempt, '') AS DATETIME) AS pickup_attempt_1,
  SAFE_CAST(NULLIF(out_for_pickup_2nd_attempt, '') AS DATETIME) AS pickup_attempt_2,
  SAFE_CAST(NULLIF(out_for_pickup_3rd_attempt, '') AS DATETIME) AS pickup_attempt_3,

  -- ---- delivery attempts ----
  SAFE_CAST(NULLIF(out_for_delivery_attempts, '') AS INT64)   AS ofd_attempts,
  SAFE_CAST(NULLIF(out_for_delivery_1st_attempt, '') AS DATETIME) AS ofd_attempt_1,
  SAFE_CAST(NULLIF(out_for_delivery_2nd_attempt, '') AS DATETIME) AS ofd_attempt_2,
  SAFE_CAST(NULLIF(out_for_delivery_3rd_attempt, '') AS DATETIME) AS ofd_attempt_3,
  NULLIF(reason_for_last_failed_delivery, '')                 AS last_failed_delivery_reason,
  NULLIF(remark_of_last_failed_delivery, '')                  AS last_failed_delivery_remark,

  -- ---- where / why ----
  current_location,
  latest_remark,

  -- ---- RVP ----
  Return_Type                                                 AS return_type,
  rvp_reason,
  other_rvp_for_order,
  other_rvp_collected,

  -- ---- origin / destination ----
  -- Forward: pickup = our warehouse, drop = customer. Reverse: pickup = customer, drop = warehouse.
  pickup_city,
  pickup_state,
  pickup_pincode,
  drop_city,
  drop_state,
  drop_pincode

FROM aged
LEFT JOIN other_rvp USING (awb)
ORDER BY pendency_type, courier, ageing_days DESC, awb
