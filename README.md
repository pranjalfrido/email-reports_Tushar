# Email Reports

Three operations reports for Frido's Shopify orders. Each one runs a BigQuery query, saves the
result as an Excel file and emails that file from `data.team@myfrido.com` through Microsoft Graph.

| Report | Question it answers | Script | Query |
|---|---|---|---|
| Cancelled, no refund | Which cancelled prepaid orders never got their money back? | `email-cancelled-no-refund.mjs` | `sql/shopify_cancelled_no_refund.sql` |
| Shopify → UC sync audit | Which Shopify orders never reached Unicommerce (UC)? | `email-uc-sync-audit.mjs` | `sql/shopify_uc_sync_audit_email.sql` |
| Order not closed | Which shipments are still open in UC although the courier has moved on? | `email-uc-order-not-closed.mjs` | `sql/uc_order_not_closed.sql` |

```
email-reports/
├── README.md
├── email-cancelled-no-refund.mjs
├── email-uc-sync-audit.mjs
├── email-uc-order-not-closed.mjs
├── lib/report-mailer.mjs     shared code: CLI flags, BigQuery, Excel, sending the email
└── sql/                      the three queries; each runs as-is in the BigQuery console
```

---

## Running a report

```bash
# build the Excel only; no email is sent (useful for checking numbers)
node email-reports/email-uc-sync-audit.mjs --dry-run

# send to one or more people
node email-reports/email-uc-sync-audit.mjs --to someone@myfrido.com
node email-reports/email-uc-sync-audit.mjs --to a@myfrido.com,b@myfrido.com --cc c@myfrido.com

# change the date window (the default is the window written in the .sql file)
node email-reports/email-uc-sync-audit.mjs --to a@myfrido.com --from 2026-10-01 --until 2026-10-31
```

| Flag | Meaning |
|---|---|
| `--to` | Comma-separated recipients. Required unless `--dry-run`. |
| `--cc` | Comma-separated CC recipients. |
| `--from`, `--until` | Order-date window, `YYYY-MM-DD`, both inclusive. |
| `--dry-run` | Build the Excel file without sending anything. |

Every run also saves the Excel file to `exports/` at the project root.

### Setup

1. **Node 20 or newer.** Run `npm install` in the project root. The scripts need
   `@google-cloud/bigquery`, `xlsx-js-style`, `fflate` and `dotenv`.
2. **BigQuery access.** Put a service-account key file named `sa_key.json` in the project root.
   It needs read access to the `frido-429506.production` dataset and permission to run query jobs.
3. **Email access.** Add these to `.env` in the project root:
   ```
   OTP_FRIDO_CLIENT_ID=<Azure app client id>
   OTP_FRIDO_TENANT_ID=<Azure tenant id>
   OTP_FRIDO_CLIENT_SECRET=<Azure app client secret>
   REPORT_MAIL_FROM=data.team@myfrido.com
   ```
   The Azure app needs the **Mail.Send** application permission, approved by an admin.

> `.env` and `sa_key.json` contain secrets and are gitignored. Never commit them or share them
> by email or chat. Ask the data team for your own copies.

### Attachment size

Microsoft Graph accepts an attachment of up to about 3 MB inside a single send request. To stay
under that, the scripts re-compress every Excel file at maximum zip level (`fflate`). The
Excel library's built-in compression is weak: a 15,000-row sheet came out at 4 MB with it and
1.4 MB re-compressed.

Files over 2.5 MB switch to Graph's upload-session method. That method also needs the
**Mail.ReadWrite** application permission, which the app does **not** have yet, so these sends
fail with `403 ErrorAccessDenied` until an admin grants it.

---

## 1. Cancelled orders – refund not triggered

**Purpose.** List prepaid Shopify orders that were cancelled but never refunded, so the
customer paid and got nothing back.

**Source table:** `production.fact_shopify_myfrido_mobility_all_orders` (one row per line item).

**Window:** `order_date_ist` from the 1st to the 30th of the month (default: September 2026).

**Logic**
- Keep orders with `cancelled_at IS NOT NULL` and `payment_type <> 'COD'`. PPCOD counts as
  prepaid.
- Collapse the line items to **one row per order**.
  - `order_total` is the sum of `final_total_incl_tax` across the order's lines, because that
    column is stored per line.
  - The refund statuses of all lines are joined into one string. Blank lines are skipped, so an
    order with no refund status anywhere comes out empty rather than as `" | "`.
- **`needs_review = TRUE`** when all three of these hold:
  1. the order is prepaid,
  2. `financial_status` is not `refunded` or `partially_refunded`,
  3. no refund transaction has the status `success`.
- **`refund_gap_reason`** explains each row:

| Reason | Meaning |
|---|---|
| financial_status shows refunded — check transaction status | Shopify says refunded. These rows are context, not flagged. |
| gateway shows success — financial_status may be stale | The gateway shows a successful refund but Shopify's status was never updated. |
| no refund record at all | No refund attempt exists. These are the main gaps. |
| refund attempted but no success status | A refund was tried and none succeeded. |

**Excel sheets**
- **Needs Review**: flagged orders, with the longest-cancelled first.
- **By Gap Reason**: order count and total value per reason.
- **All Cancelled Prepaid**: every cancelled prepaid order in the window.

**Email**
- **Subject:** `Cancelled orders – refund not triggered | <from> to <until> | <N> to review`
- **Body:**
  - the number of cancelled prepaid orders,
  - the number needing review,
  - **"No refund status, but Shopify note available"**: flagged orders with no refund status
    whose Shopify order note is filled in. The note is usually `Size edited #MF…` or `#MF…`,
    which means the order was re-placed, so the payment probably moved to the new order and no
    refund was due.
  - a table of gap reasons with order count and order total.

**September 2026 example:** 4,755 cancelled prepaid orders, 852 needing review. 797 of those
have a Shopify note, which leaves about 54 with no refund status and no explanation.

---

## 2. Shopify → Unicommerce sync audit

**Purpose.** Check that every Shopify order was created in Unicommerce, the warehouse system.
An order missing from UC never gets picked, packed or shipped.

**Source tables**
- `production.fact_shopify_myfrido_mobility_all_orders`: Shopify, line level
- `production.Unicommerce_Sale_Orders_Report`: UC, item level, about 8.2 million rows
- `production.Clickpost_Shipment_Tracking_Report`: courier tracking, used for reference columns

**Windows**
- Shopify orders: 21–30 Sep 2026 by default.
- UC and Clickpost: the same start date, but running **7 days past** the end date. An order
  placed on 30 Sep can reach UC on 1 Oct, and equal windows would count that delay as a missing
  order. `--from`/`--until` move all three windows together.

**Decision tree (column `x_verdict`)**

| # | Condition | Verdict |
|---|---|---|
| 1 | Found in UC | OK - in Unicommerce |
| 2 | Not in UC, tagged both `Retail Store` and `CASH_AND_CARRY` | OK - retail cash & carry (sold in store, nothing to ship) |
| 3 | Not in UC, tagged `Retail Store` without cash & carry | **HIGHLIGHT - retail online, not in UC** |
| 4 | Not in UC, tagged `ORDER_CANCELLED_CP` | OK - cancelled before UC |
| 5 | SKU `COUP500` / `COUP1000` | Excluded before the check: these are free promotional lines with no goods |
| 6 | Anything else not in UC | **HIGHLIGHT - missing from UC** |

`x_needs_review = TRUE` for the two HIGHLIGHT verdicts.

**Matching rules worth knowing**
- **Two keys.** An order counts as missing only when **both** of these fail to match:
  - UC `SaleOrderCode` against Shopify `order_id`. UC stores it with a leading backtick, which
    is stripped first.
  - UC `DisplayOrderCode` against Shopify `order_name`. The `#` is stripped, as is any exchange
    suffix such as `_EX486_EX744`.
  Matching on the name alone overstates the gap about 4×, because of formatting differences.
- **UC date column.** UC's `OrderDate` column is entirely NULL. The real order date is in
  `OrderDateasddmmyyyyhhMMss`.
- **One row per UC order.** UC rows are collapsed to one per order before the join, so a
  three-item UC order doesn't triple each Shopify line.

**Excel sheets**
- **Needs Review**: flagged lines with every Shopify column, the UC match details and the
  `x_` helper columns.
- **Summary**: orders, lines and line value for every verdict, including the OK ones.

The full list of every audited line (about 89,000 lines × 120 columns) is left out because it is
far too large to email.

**Email**
- **Subject:** `Shopify → UC sync audit | <from> to <until> | <N> orders to review`
- **Body:**
  - orders and lines audited,
  - orders and lines needing review,
  - a table of the HIGHLIGHT verdicts with orders, lines and line value,
  - a short explanation of each verdict and of what is deliberately not flagged.

**21–30 Sep 2026 example**

| Verdict | Orders | Lines |
|---|---|---|
| OK - in Unicommerce | 66,176 | 86,669 |
| OK - retail cash & carry | 1,353 | 1,808 |
| OK - cancelled before UC | 177 | 207 |
| **HIGHLIGHT - missing from UC** | **36** | **40** |

---

## 3. Order not closed – UC vs Clickpost

**Purpose.** Find shipments where Unicommerce still shows an open status but the courier,
according to Clickpost, has already picked up, delivered or returned the parcel. The usual
cause is a manifest that was never closed at the warehouse, or a UC record that was never
updated afterwards.

**Source tables:** the same three as report 2. Shopify is used only as a filter, so that only
Shopify-channel orders are included.

**Window:** Shopify and UC order dates from the 1st to the 30th of the month (default: September
2026). Clickpost has no date filter: it is limited to the AWBs found in the UC window.

**Grain:** one row per **AWB** (tracking number). UC items are grouped by `TrackingNumber` and
joined to Clickpost's latest scan for that AWB.

**UC status flow**
```
CREATED > PICKING > PICKED > PACKED > READY_TO_SHIP > MANIFESTED > DISPATCHED > SHIPPED > DELIVERED / RETURNED
                                      └── manifest still OPEN ───┘ └── manifest CLOSED ──┘
```

Both statuses are mapped to stages so they can be compared:

| Stage | UC package status | Clickpost status |
|---|---|---|
| 0 | CREATED, PICKING, PICKED, PACKED | OrderPlaced, Awb Registered, NoStatusExist, NotServiceable |
| 1 | READY_TO_SHIP, MANIFESTED | OutForPickup, PickupPending, PickupFailed |
| 2 | – | PickedUp |
| 3 | DISPATCHED, SHIPPED | InTransit, OutForDelivery, FailedDelivery, ShipmentDelayed, … |
| 4 | DELIVERED | Delivered, RTO-Delivered |
| 9 | RETURNED, RETURN_EXPECTED | Cancelled, Lost, and **anything not listed** |

Only rows where UC is still open are kept (UC stage 3 or below, or an unmapped UC status).

**Issue types (column `issue_type`, checked in this order)**

| Issue | Rule | What it means |
|---|---|---|
| NOT_IN_CLICKPOST | No Clickpost record for the AWB | The courier never registered the shipment. |
| MANIFEST_NOT_CLOSED | UC at READY_TO_SHIP/MANIFESTED, Clickpost at PickedUp or beyond | The parcel left the warehouse but the manifest was never closed. |
| NOT_SCANNED_BY_COURIER_YET | UC at DISPATCHED/SHIPPED, Clickpost at stage 0–1 | UC says handed over, the courier has no pickup scan yet. |
| UC_NOT_UPDATED_AFTER_DELIVERY | UC at DISPATCHED/SHIPPED, Clickpost Delivered or RTO-Delivered | UC was never updated after the parcel arrived. |
| RTO_NOT_REFLECTED_IN_UC | UC at DISPATCHED/SHIPPED, Clickpost at stage 9 | The courier returned, cancelled or lost it; UC still shows in transit. |
| STAGE_GAP_REVIEW | Anything else | Catch-all. |

`days_open` is today minus the UC package creation date. Use it for priority.

**Excel sheets**
- **Summary**: per issue, the AWB count, how many have been open more than 7 days, the oldest
  in days, and a one-line meaning.
- **Order Not Closed**: one row per AWB, sorted by issue and then oldest first.

**Email**
- **Subject:** `Order not closed – UC vs Clickpost | <from> to <until> | <N> AWBs`
- **Body:**
  - the total number of open AWBs flagged,
  - the manifest-not-closed count,
  - the summary table above.

**September 2026 example (about 15,300–15,700 AWBs; the number moves as the data updates)**

| Issue | AWBs | Over 7 days open |
|---|---|---|
| UC_NOT_UPDATED_AFTER_DELIVERY | 10,493 | 10,418 |
| RTO_NOT_REFLECTED_IN_UC | 2,120 | 2,096 |
| MANIFEST_NOT_CLOSED | 1,807 | 1,767 |
| STAGE_GAP_REVIEW | 1,182 | 985 |
| NOT_SCANNED_BY_COURIER_YET | 51 | 50 |
| NOT_IN_CLICKPOST | 15 | 15 |

**Known caveats (not yet changed in the query)**
- **STAGE_GAP_REVIEW is mostly normal shipments.** Most of it is UC Dispatched/Shipped with
  Clickpost In Transit or Out for Delivery, which are parcels simply in transit. The final
  WHERE clause has a comment, "AND courier has moved further than UC", that was never written as
  a condition. Adding it would remove these rows.
- **UC_NOT_UPDATED_AFTER_DELIVERY is mostly returns.** About 10,360 of the 10,493 are
  **RTO-Delivered**: parcels back at the warehouse but not marked RETURNED in UC. Only about 130
  are customer deliveries. The two cases may belong to different teams.
- **Some RTO statuses are classified by default.** `RTO-InTransit`, `RTO-OutForDelivery` and
  `RTO-Requested` aren't in the Clickpost stage mapping, so they fall to stage 9 through the
  `ELSE` branch and end up under RTO_NOT_REFLECTED_IN_UC.

---

## Adding a fourth report

1. Put the query in `sql/`. Keep the date window as literal `BETWEEN 'YYYY-MM-DD' AND 'YYYY-MM-DD'`
   strings, because the scripts find and replace those to apply `--from`/`--until`.
2. Copy the shortest existing script, `email-uc-sync-audit.mjs`, and change:
   - the SQL file name,
   - the summary it builds,
   - the email body and subject.
3. Run it with `--dry-run`, check the Excel file in `exports/`, then send a test to yourself.
