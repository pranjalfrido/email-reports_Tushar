-- SHOPIFY: CANCELLED ORDERS WHERE REFUND WAS NOT TRIGGERED, Sep 2026.
--
-- THE CASE: Shopify financial_status = 'refunded' or 'partially_refunded' is the end state,
-- but this query looks upstream -- orders that were CANCELLED (cancelled_at IS NOT NULL)
-- without any successful refund ever being processed. These are the ones where the customer
-- got a cancellation but no money back.
--
-- ===================== WHAT "REFUND NOT TRIGGERED" MEANS =====================
-- Three independent checks, all of which must be true for the flag:
--   1. cancelled_at IS NOT NULL           -- Shopify did cancel the order
--   2. financial_status NOT IN ('refunded','partially_refunded')
--                                         -- Shopify's own ledger shows no refund
--   3. No 'success' in refund_transaction_status
--                                         -- the payment gateway confirms no payout
--
-- financial_status alone is unreliable in isolation: it can read 'paid' on a cancelled order
-- that never got a refund, or 'pending' while a refund is in flight. The transaction status
-- check is the ground truth; financial_status is the corroborating signal.
--
-- ===================== REFUND COLUMN SHAPE =====================
-- refunds_processed_at and refund_transaction_status are PIPE-DELIMITED STRINGS, not scalars.
-- An order with three refund attempts carries "ts | ts | ts" and "success | failure | success".
-- The query flattens the status list and checks for ANY 'success' token -- the order is
-- considered refunded if any one attempt succeeded, even if others failed.
--
-- ===================== PREPAID vs COD =====================
-- A COD order that was cancelled before delivery never collected money, so no refund can be
-- expected. The flag is_prepaid (payment_type != 'COD'; PPCOD counts as prepaid) separates these: TRUE = money was taken, refund was owed;
-- FALSE = COD, no money to return. Filter on is_prepaid = TRUE to see only genuine gaps.
--
-- ===================== GRAIN =====================
-- One row per ORDER, not per line item. The refund gap is an order-level problem: the whole
-- order was cancelled and the whole payment was not returned. Summing line value gives the
-- total amount at risk.
--
-- ===================== WINDOW =====================
-- September 2026. Extend order_date_ist range to change the window.

WITH base AS (
  SELECT
    order_id,
    order_name,
    source_system,
    order_date_ist,
    DATETIME(created_at_utc, 'Asia/Kolkata')    AS order_placed_at_ist,
    DATETIME(cancelled_at,   'Asia/Kolkata')    AS order_cancelled_at_ist,
    cancel_reason,
    financial_status,
    tags,
    payment_type,
    payment_gateway_names,
    note,
    final_total_incl_tax,
    selling_price_excl_shipping_tax,
    refunds_processed_at,
    refund_transaction_status
  FROM `frido-429506.production.fact_shopify_myfrido_mobility_all_orders`
  WHERE order_date_ist BETWEEN '2026-09-01' AND '2026-09-30'
    AND cancelled_at IS NOT NULL          -- only cancelled orders
    AND COALESCE(payment_type, '') != 'COD'  -- exclude COD only; PPCOD is prepaid, kept in
),

-- One row per order: aggregate line items, flatten refund status once.
per_order AS (
  SELECT
    order_id,
    ANY_VALUE(order_name)               AS order_name,
    ANY_VALUE(source_system)            AS store,
    ANY_VALUE(order_date_ist)           AS order_date,
    ANY_VALUE(order_placed_at_ist)      AS order_placed_at_ist,
    ANY_VALUE(order_cancelled_at_ist)   AS order_cancelled_at_ist,
    ANY_VALUE(cancel_reason)            AS cancel_reason,
    ANY_VALUE(financial_status)         AS financial_status,
    ANY_VALUE(tags)                     AS tags,
    ANY_VALUE(payment_type)             AS payment_type,
    ANY_VALUE(payment_gateway_names)    AS payment_gateway_names,
    ANY_VALUE(note)                     AS shopify_note,
    SUM(final_total_incl_tax)           AS order_total,   -- line-level column; sum to order
    SUM(selling_price_excl_shipping_tax) AS total_selling_price,
    -- Flatten all pipe-delimited statuses into one string for the LIKE check.
    -- Skip blank lines so an order with no status anywhere yields NULL, not ' | '.
    STRING_AGG(NULLIF(TRIM(refund_transaction_status), ''), ' | ')
      AS all_refund_statuses
  FROM base
  GROUP BY order_id
)

SELECT
  order_id,
  order_name,
  store,
  order_date,
  order_placed_at_ist,
  order_cancelled_at_ist,
  cancel_reason,
  financial_status,
  payment_type,
  payment_gateway_names,

  -- Is this a prepaid order? COD cancellations don't owe a refund.
  COALESCE(payment_type, '') != 'COD' AS is_prepaid,

  ROUND(order_total, 2)         AS order_total,
  ROUND(total_selling_price, 2) AS total_selling_price,

  -- Why the refund is flagged as missing.
  CASE
    WHEN financial_status IN ('refunded', 'partially_refunded')
      THEN 'financial_status shows refunded — check transaction status'
    WHEN all_refund_statuses LIKE '%success%'
      THEN 'gateway shows success — financial_status may be stale'
    WHEN all_refund_statuses IS NULL OR TRIM(all_refund_statuses) = ''
      THEN 'no refund record at all'
    ELSE 'refund attempted but no success status'
  END AS refund_gap_reason,

  -- TRUE = genuinely missing refund on a prepaid order.
  (
    COALESCE(payment_type, '') != 'COD'
    AND COALESCE(financial_status, '') NOT IN ('refunded', 'partially_refunded')
    AND COALESCE(all_refund_statuses, '') NOT LIKE '%success%'
  ) AS needs_review,

  all_refund_statuses AS raw_refund_statuses,
  shopify_note,

  DATE_DIFF(CURRENT_DATE('Asia/Kolkata'), DATE(order_cancelled_at_ist), DAY)
    AS days_since_cancellation,

  -- Shopify tag splits useful for triage.
  REGEXP_CONTAINS(COALESCE(tags, ''), r'COD')           AS is_cod_tag,
  REGEXP_CONTAINS(COALESCE(tags, ''), r'GoKwik')        AS is_gokwik,
  REGEXP_CONTAINS(COALESCE(tags, ''), r'Retail Store')  AS is_retail_store,
  tags

FROM per_order
ORDER BY
  needs_review DESC,
  days_since_cancellation DESC,
  order_total DESC
