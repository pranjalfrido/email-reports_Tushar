-- Shopify -> Unicommerce sync audit, 21-30 Sep 2026.
-- Every Shopify line is returned with a verdict: OK, or HIGHLIGHT with the reason.
-- Used by email-reports/email-uc-sync-audit.mjs (the email overrides the date windows).
--
-- ===================== THE DECISION TREE =====================
--   1. In Unicommerce?                                        -> OK
--   2. Not in UC, but Retail Store AND CASH_AND_CARRY (both)   -> OK (POS, nothing to ship)
--   3. Not in UC, Retail Store but NOT cash & carry            -> HIGHLIGHT (retail online)
--   4. Not in UC, but ORDER_CANCELLED_CP                       -> OK (killed before the WMS)
--   5. Coupon SKUs (COUP500 / COUP1000)                        -> EXCLUDED, not shippable
--   6. Anything else not in UC                                 -> HIGHLIGHT
--
-- ===================== KEY NOTES =====================
-- MATCHED ON TWO KEYS; absent only if BOTH miss:
--   SaleOrderCode    = Shopify order_id, stored with a leading backtick (an Excel text-guard
--                      that survived the load).
--   DisplayOrderCode = Shopify order_name (#MF0223581094), sometimes with an exchange suffix
--                      (#MF0223336027_EX486_EX744) that must be stripped.
-- Matching on the name alone overstates the gap ~4x -- format noise, not absent orders.
--
-- UC date column: OrderDate is 100% NULL across all 8.2M rows. The real one is
-- OrderDateasddmmyyyyhhMMss.
--
-- The UC window runs 7 days past the Shopify one: an order placed 30 Sep can reach UC on
-- 1 Oct, and equal windows would count that lag as a missing order.
--
-- COUPON SKUs: COUP500 and COUP1000 are zero-price promotional lines -- 23,875 of them in
-- this window, which makes COUP500 the single most frequent "SKU" of the month. They carry
-- no goods, so Unicommerce has nothing to create; left in, they would dominate the
-- highlight list with noise.
--
-- RETAIL: a sale tagged BOTH Retail Store and CASH_AND_CARRY is collected in store -- no
-- pick, pack or ship, so UC is not expected to hold it. Tagged Retail Store WITHOUT cash &
-- carry is a store order that ships, which SHOULD be in UC -- hence rule 3.
-- Caveat: 58 retail orders DID reach UC in September, so "retail never syncs" is not a rule
-- the data supports. These verdicts encode expectation, not proof.
WITH uc AS (
  SELECT REGEXP_REPLACE(TRIM(SaleOrderCode), r'^[`\s]+', '')                          AS oid,
         UPPER(REGEXP_REPLACE(TRIM(REPLACE(DisplayOrderCode,'#','')), r'_EX.*$', '')) AS nm,
         -- One row per order key: UC is item-level, so an order with 3 lines would
         -- otherwise fan each Shopify line into 3 and inflate the export.
         ANY_VALUE(SaleOrderCode)             AS uc_sale_order_code,
         ANY_VALUE(DisplayOrderCode)          AS uc_display_order_code,
         ANY_VALUE(SaleOrderStatus)           AS uc_sale_order_status,
         ANY_VALUE(SaleOrderItemStatus)       AS uc_item_status,
         ANY_VALUE(ShippingPackageStatusCode) AS uc_package_status,
         ANY_VALUE(ChannelName)               AS uc_channel,
         ANY_VALUE(Shippingprovider)          AS uc_shipping_provider,
         MIN(DATE(OrderDateasddmmyyyyhhMMss)) AS uc_order_date,
         MAX(DATE(DispatchDate_dtm))          AS uc_dispatch_date,
         COUNT(*)                             AS uc_item_rows
    FROM `frido-429506.production.Unicommerce_Sale_Orders_Report`
   WHERE DATE(OrderDateasddmmyyyyhhMMss) BETWEEN '2026-09-21' AND '2026-10-07'
   GROUP BY 1, 2
),
cp AS (
  -- Latest tracking row per order: an order can carry several AWBs (split shipments,
  -- re-ships), so rank rather than aggregate blindly.
  SELECT * EXCEPT(rn) FROM (
    SELECT UPPER(TRIM(REPLACE(order_id,'#',''))) AS nm,
           clickpost_unified_status AS cp_status,
           awb AS cp_awb,
           DATE(delivery_date) AS cp_delivery_date,
           ROW_NUMBER() OVER (PARTITION BY UPPER(TRIM(REPLACE(order_id,'#','')))
                              ORDER BY updated_at DESC) AS rn
      FROM `frido-429506.production.Clickpost_Shipment_Tracking_Report`
     WHERE DATE(order_date) BETWEEN '2026-09-21' AND '2026-10-07'
  ) WHERE rn = 1
),
sh AS (
  SELECT *,
         CAST(order_id AS STRING)                AS _oid,
         UPPER(TRIM(REPLACE(order_name,'#','')))  AS _nm
    FROM `frido-429506.production.fact_shopify_myfrido_mobility_all_orders`
   WHERE order_date_ist BETWEEN '2026-09-21' AND '2026-09-30'
     -- Rule 5. Promotional lines carry no goods, so there is nothing for UC to create.
     AND COALESCE(sku,'') NOT IN ('COUP500','COUP1000')
),
j AS (
  SELECT sh.* EXCEPT(_oid, _nm),
         (u_oid.oid IS NOT NULL OR u_nm.nm IS NOT NULL) AS found_in_uc,
         CASE WHEN u_oid.oid IS NOT NULL AND u_nm.nm IS NOT NULL THEN 'both'
              WHEN u_oid.oid IS NOT NULL THEN 'order_id'
              WHEN u_nm.nm  IS NOT NULL THEN 'order_name'
              ELSE 'none' END                            AS uc_match_key,
         COALESCE(u_oid.uc_sale_order_code,    u_nm.uc_sale_order_code)    AS uc_sale_order_code,
         COALESCE(u_oid.uc_display_order_code, u_nm.uc_display_order_code) AS uc_display_order_code,
         COALESCE(u_oid.uc_sale_order_status,  u_nm.uc_sale_order_status)  AS uc_sale_order_status,
         COALESCE(u_oid.uc_item_status,        u_nm.uc_item_status)        AS uc_item_status,
         COALESCE(u_oid.uc_package_status,     u_nm.uc_package_status)     AS uc_package_status,
         COALESCE(u_oid.uc_channel,            u_nm.uc_channel)            AS uc_channel,
         COALESCE(u_oid.uc_shipping_provider,  u_nm.uc_shipping_provider)  AS uc_shipping_provider,
         COALESCE(u_oid.uc_order_date,         u_nm.uc_order_date)         AS uc_order_date,
         COALESCE(u_oid.uc_dispatch_date,      u_nm.uc_dispatch_date)      AS uc_dispatch_date,
         COALESCE(u_oid.uc_item_rows,          u_nm.uc_item_rows)          AS uc_item_rows,
         cp.cp_status, cp.cp_awb, cp.cp_delivery_date
    FROM sh
    -- Two separate joins rather than one OR: an OR join cannot hash-join and turns this
    -- into a cross product over 8.2M UC rows.
    LEFT JOIN uc AS u_oid ON u_oid.oid = sh._oid AND u_oid.oid <> ''
    LEFT JOIN uc AS u_nm  ON u_nm.nm  = sh._nm
    LEFT JOIN cp          ON cp.nm    = sh._nm
)
SELECT * EXCEPT(cp_status, cp_awb, cp_delivery_date),

       -- ===================== DERIVED HELPER COLUMNS =====================
       -- Everything above is source data, untouched. Everything below is computed.
       cp_status                                                     AS x_cp_status,
       cp_awb                                                        AS x_cp_awb,
       cp_delivery_date                                              AS x_cp_delivery_date,

       REGEXP_CONTAINS(COALESCE(tags,''), r'Retail Store')           AS x_is_retail_store,
       REGEXP_CONTAINS(COALESCE(tags,''), r'CASH_AND_CARRY')         AS x_is_cash_and_carry,
       REGEXP_CONTAINS(COALESCE(tags,''), r'ORDER_CANCELLED_CP')     AS x_is_cancelled_cp,

       -- THE VERDICT. One column to filter on.
       CASE
         WHEN found_in_uc THEN 'OK - in Unicommerce'
         WHEN REGEXP_CONTAINS(COALESCE(tags,''), r'Retail Store')
          AND REGEXP_CONTAINS(COALESCE(tags,''), r'CASH_AND_CARRY')
              THEN 'OK - retail cash & carry'
         -- Checked BEFORE the cancel rule: a retail-online order that is missing is a sync
         -- gap whether or not it was later cancelled, and the cancel tag would mask it.
         WHEN REGEXP_CONTAINS(COALESCE(tags,''), r'Retail Store')
              THEN 'HIGHLIGHT - retail online, not in UC'
         WHEN REGEXP_CONTAINS(COALESCE(tags,''), r'ORDER_CANCELLED_CP')
              THEN 'OK - cancelled before UC'
         ELSE 'HIGHLIGHT - missing from UC'
       END                                                           AS x_verdict,

       CASE
         WHEN found_in_uc THEN FALSE
         WHEN REGEXP_CONTAINS(COALESCE(tags,''), r'Retail Store')
          AND REGEXP_CONTAINS(COALESCE(tags,''), r'CASH_AND_CARRY') THEN FALSE
         WHEN REGEXP_CONTAINS(COALESCE(tags,''), r'Retail Store')  THEN TRUE
         WHEN REGEXP_CONTAINS(COALESCE(tags,''), r'ORDER_CANCELLED_CP') THEN FALSE
         ELSE TRUE
       END                                                           AS x_needs_review,

       -- Tag splits, so the common triage cuts need no string parsing in the sheet.
       REGEXP_CONTAINS(COALESCE(tags,''), r'COD')                    AS x_tag_cod,
       REGEXP_CONTAINS(COALESCE(tags,''), r'GoKwik')                 AS x_tag_gokwik,
       REGEXP_EXTRACT(COALESCE(tags,''), r'(uc-shipping-[a-z]+)')    AS x_tag_uc_lane,
       REGEXP_CONTAINS(COALESCE(tags,''), r'NDD')                    AS x_tag_next_day
  FROM j
 ORDER BY x_needs_review DESC, order_date_ist, order_name
