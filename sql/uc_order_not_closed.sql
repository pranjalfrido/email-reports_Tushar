-- SHEET 1: ORDER NOT CLOSED — UC status still open but Clickpost shows movement/delivery
-- Used by email-reports/email-uc-order-not-closed.mjs (the email overrides the date windows).
--
-- Anchor: Unicommerce_Sale_Orders_Report filtered to Shopify orders only (joined via AWB to Clickpost)
-- Grain:  One row per AWB (latest UC status + latest Clickpost scan)
-- Window: September 2026 (01 Sep – 30 Sep) for both UC and Clickpost
--
-- ===================== UC STATUS FLOW =====================
-- created > picking > picked > packed > READY_TO_SHIP > MANIFESTED
--   → DISPATCHED (manifest closed, handed to courier)
--   → SHIPPED → DELIVERED / RETURNED
--
-- MANIFESTED / READY_TO_SHIP = manifest still OPEN (parcel not yet handed to courier)
-- DISPATCHED / SHIPPED       = manifest already CLOSED (parcel is with the courier)
--
-- ===================== ISSUE TYPES =====================
--   MANIFEST_NOT_CLOSED        — UC at RTS/Manifested, but Clickpost shows PickedUp or beyond.
--                                 Parcel physically left the warehouse but manifest was never closed.
--   NOT_SCANNED_BY_COURIER_YET — UC dispatched/shipped (manifest closed), but courier has no
--                                 pickup scan yet. Could be a scan delay or genuine non-handover.
--   UC_NOT_UPDATED_AFTER_DELIVERY — UC still shows Dispatched/Shipped but Clickpost says
--                                 Delivered or RTO-Delivered. UC was not updated post-delivery.
--   RTO_NOT_REFLECTED_IN_UC    — Courier RTO'd/Lost the shipment, UC still shows in-transit.
--   NOT_IN_CLICKPOST           — AWB exists in UC but Clickpost has no record.
--
-- ===================== JOIN =====================
-- UC → Clickpost on TrackingNumber = awb (same physical label).
-- UC is item-level; GROUP BY AWB collapses items to one row per shipment.

-- Shopify orders September 2026 — used to restrict UC to Shopify channel only.
-- Joined on cleaned order_name (# stripped, uppercased) which matches UC's DisplayOrderCode.
with sh AS (
  SELECT DISTINCT
    UPPER(TRIM(REPLACE(order_name, '#', ''))) AS order_name_clean
  FROM `frido-429506.production.fact_shopify_myfrido_mobility_all_orders`
  WHERE order_date_ist BETWEEN '2026-09-01' AND '2026-09-30'
),

uc AS (
  SELECT
    CAST(ANY_VALUE(TrackingNumber) AS STRING)            AS awb,
    REGEXP_REPLACE(TRIM(ANY_VALUE(SaleOrderCode)), r'^[`\s]+', '')  AS uc_order_id,
    UPPER(REGEXP_REPLACE(TRIM(REPLACE(ANY_VALUE(DisplayOrderCode),'#','')), r'_EX.*$',''))
                                                         AS uc_order_name,
    ANY_VALUE(ShippingPackageStatusCode)                 AS uc_package_status,
    ANY_VALUE(SaleOrderItemStatus)                       AS uc_item_status,
    ANY_VALUE(Shippingprovider)                          AS uc_courier,
    ANY_VALUE(Facility)                                  AS facility,
    MAX(DATE(ShippingPackageCreationDate_dtm))           AS package_created_date,
    MAX(DATE(DispatchDate_dtm))                          AS uc_dispatch_date,
    COUNT(*)                                             AS uc_item_rows,
    COUNTIF(SaleOrderItemStatus = 'CANCELLED')           AS uc_cancelled_items,
    STRING_AGG(DISTINCT ItemSKUCode, ', ' ORDER BY ItemSKUCode)  AS uc_skus
  FROM `frido-429506.production.Unicommerce_Sale_Orders_Report`
  WHERE DATE(OrderDateasddmmyyyyhhMMss) BETWEEN '2026-09-01' AND '2026-09-30'
    AND CAST(TrackingNumber AS STRING) IS NOT NULL
    AND TRIM(CAST(TrackingNumber AS STRING)) <> ''
  GROUP BY CAST(TrackingNumber AS STRING)  -- one row per AWB
),

-- Keep only UC rows whose order name exists in Shopify (Shopify channel filter)
uc_shopify AS (
  SELECT uc.*
  FROM uc
  INNER JOIN sh ON sh.order_name_clean = uc.uc_order_name
),

cp AS (
  -- Latest Clickpost scan per AWB.
  -- No date filter here — Clickpost's order_date can differ from UC's order date.
  -- Scoping is done via the JOIN: only AWBs that exist in the UC September window are kept.
  SELECT * EXCEPT (rn)
  FROM (
    SELECT
      CAST(awb AS STRING)             AS awb,
      clickpost_unified_status        AS cp_status,
      courier_partner                 AS cp_courier,
      DATE(pickup_date)               AS cp_pickup_date,
      DATE(delivery_date)             AS cp_delivery_date,
      DATE(updated_at)                AS cp_last_scan_date,
      ROW_NUMBER() OVER (
        PARTITION BY CAST(awb AS STRING)
        ORDER BY updated_at DESC
      ) AS rn
    FROM `frido-429506.production.Clickpost_Shipment_Tracking_Report`
  )
  WHERE rn = 1
),

joined AS (
  SELECT
    uc.awb,
    uc.uc_order_id,
    uc.uc_order_name,
    uc.uc_package_status,
    uc.uc_item_status,
    uc.uc_courier,
    uc.facility,
    uc.package_created_date,
    uc.uc_dispatch_date,
    uc.uc_item_rows,
    uc.uc_cancelled_items,
    uc.uc_skus,
    cp.cp_status,
    cp.cp_courier,
    cp.cp_pickup_date,
    cp.cp_delivery_date,
    cp.cp_last_scan_date,

    -- UC stage (0 = pre-pickup, 1 = manifested/RTS, 2 = picked up, 3 = in transit, 4 = delivered, 9 = RTO/cancelled)
    CASE uc.uc_package_status
      WHEN 'DELIVERED'       THEN 4
      WHEN 'DISPATCHED'      THEN 3
      WHEN 'SHIPPED'         THEN 3
      WHEN 'MANIFESTED'      THEN 1
      WHEN 'READY_TO_SHIP'   THEN 1
      WHEN 'PACKED'          THEN 0
      WHEN 'PICKED'          THEN 0
      WHEN 'PICKING'         THEN 0
      WHEN 'CREATED'         THEN 0
      WHEN 'RETURNED'        THEN 9
      WHEN 'RETURN_EXPECTED' THEN 9
      ELSE NULL
    END AS uc_stage,

    -- Clickpost stage
    CASE cp.cp_status
      WHEN 'Delivered'           THEN 4
      WHEN 'RTO-Delivered'       THEN 4
      WHEN 'OutForDelivery'      THEN 3
      WHEN 'DestinationHubIn'    THEN 3
      WHEN 'InTransit'           THEN 3
      WHEN 'OriginCityOut'       THEN 3
      WHEN 'OriginCityIn'        THEN 3
      WHEN 'ShipmentDelayed'     THEN 3
      WHEN 'ShipmentHeld'        THEN 3
      WHEN 'FailedDelivery'      THEN 3
      WHEN 'ContactCustomerCare' THEN 3
      WHEN 'PickedUp'            THEN 2
      WHEN 'OutForPickup'        THEN 1
      WHEN 'PickupPending'       THEN 1
      WHEN 'PickupFailed'        THEN 1
      WHEN 'OrderPlaced'         THEN 0
      WHEN 'Awb Registered'      THEN 0
      WHEN 'NoStatusExist'       THEN 0
      WHEN 'NotServiceable'      THEN 0
      WHEN 'Cancelled'           THEN 9
      WHEN 'Lost'                THEN 9
      ELSE 9
    END AS cp_stage

  FROM uc_shopify AS uc
  LEFT JOIN cp ON cp.awb = uc.awb
)

SELECT
  -- ---- Issue classification ----
  CASE
    WHEN cp_status IS NULL
      THEN 'NOT_IN_CLICKPOST'

    -- ---------------------------------------------------------------
    -- FLOW: created > picking > packed > RTS > MANIFESTED > DISPATCHED > SHIPPED > delivered
    --
    -- MANIFESTED / READY_TO_SHIP = manifest is still OPEN (not yet closed/handed to courier)
    -- DISPATCHED / SHIPPED       = manifest already CLOSED; parcel is with courier
    -- ---------------------------------------------------------------

    -- Manifest genuinely not closed: UC still at RTS/Manifested stage
    -- but courier already has the parcel (picked up, in transit, delivered, or RTO'd).
    WHEN uc_package_status IN ('READY_TO_SHIP','MANIFESTED')
     AND cp_stage >= 2   -- PickedUp or beyond
      THEN 'MANIFEST_NOT_CLOSED'

    -- UC shows dispatched/shipped (manifest already closed, parcel handed over)
    -- but Clickpost still has no pickup scan — courier hasn't scanned it yet.
    WHEN uc_package_status IN ('DISPATCHED','SHIPPED')
     AND cp_stage IN (0, 1)  -- OrderPlaced / Awb Registered / PickupPending / PickupFailed
      THEN 'NOT_SCANNED_BY_COURIER_YET'

    -- UC shows dispatched/shipped (in transit with courier)
    -- but Clickpost already shows Delivered or RTO-Delivered.
    -- UC was not updated after delivery — UC is behind, not a manifest issue.
    WHEN uc_package_status IN ('DISPATCHED','SHIPPED')
     AND cp_status IN ('Delivered','RTO-Delivered')
      THEN 'UC_NOT_UPDATED_AFTER_DELIVERY'

    -- UC shows dispatched/shipped, courier RTO'd or lost — UC still shows in-transit
    WHEN uc_package_status IN ('DISPATCHED','SHIPPED')
     AND cp_stage = 9
      THEN 'RTO_NOT_REFLECTED_IN_UC'

    -- Catch-all: some other stage gap worth reviewing
    ELSE 'STAGE_GAP_REVIEW'
  END AS issue_type,

  -- How many days this has been open (priority column)
  DATE_DIFF(
    CURRENT_DATE('Asia/Kolkata'),
    COALESCE(package_created_date, CURRENT_DATE('Asia/Kolkata')),
    DAY
  ) AS days_open,

  -- ---- Shipment identity ----
  awb,
  uc_order_id,
  uc_order_name,
  uc_skus,
  uc_courier,
  cp_courier,
  facility,

  -- ---- UC status ----
  uc_package_status,
  uc_item_status,
  uc_stage,
  package_created_date,
  uc_dispatch_date,
  uc_item_rows,
  uc_cancelled_items,

  -- ---- Clickpost status ----
  cp_status,
  cp_stage,
  cp_pickup_date,
  cp_delivery_date,
  cp_last_scan_date

FROM joined
WHERE
  -- Only rows where UC is still "open" (not yet delivered/returned in UC)
  uc_stage IS NULL OR uc_stage <= 3
  -- AND courier has moved further than UC, OR courier data is absent
  -- (stage gap >= 1 OR not in Clickpost at all)

ORDER BY
  issue_type,
  days_open DESC,
  awb
