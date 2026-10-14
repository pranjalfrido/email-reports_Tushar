// Runs email-reports/sql/clickpost_pendency.sql (every open Clickpost shipment, bucketed by
// where it is stuck) and emails courier x ageing pivots with the AWB-level detail attached.
//
//   node email-reports/email-clickpost-pendency.mjs --to tushar.g@myfrido.com
//   node email-reports/email-clickpost-pendency.mjs --to a@x.com,b@x.com --cc c@x.com
//   node email-reports/email-clickpost-pendency.mjs --dry-run        (build the xlsx, don't send)
//
// The window is a rolling 45 days of AWB creation, set in the SQL; --from/--until are not used.

import { readFileSync, writeFileSync } from 'fs'
import { join } from 'path'
import { ROOT, SQL_DIR, parseArgs, queryRows, writeWorkbook, htmlTable, sendReport } from './lib/report-mailer.mjs'

const opts = parseArgs()
const sql = readFileSync(join(SQL_DIR, 'clickpost_pendency.sql'), 'utf8')

console.log('Querying open Clickpost shipments (AWBs created in the last 45 days) ...')
const rows = await queryRows(sql, { stringCols: ['awb', 'order_id'] })
const today = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' })
const fmt = (n) => n.toLocaleString('en-IN')

const TYPES = [
  ['1. Pickup pending', 'Pickup pending', 'not yet picked up; ageing from AWB creation'],
  ['2. Hub scan pending', 'Hub scan pending after pickup', 'picked up but no hub in-scan yet; ageing from pickup'],
  ['3. Delivery pending', 'Delivery pending', 'in transit to the customer; ageing from pickup'],
  ['4. RTO delivery pending', 'RTO delivery pending', 'returning to origin; ageing from RTO mark date'],
  ['5. RVP pickup pending', 'RVP pickup pending', 'reverse pickup not yet collected from the customer; ageing from AWB creation'],
  ['6. RVP delivery pending', 'RVP delivery pending', 'reverse pickup collected, not yet back at the warehouse; ageing from pickup'],
  ['7. Unmapped status', 'Unmapped status', 'a Clickpost status this report does not recognise yet; it needs adding to the status lists in clickpost_pendency.sql'],
]
const BUCKETS = ['0-1 d', '2-3 d', '4-7 d', '8-15 d', '16-30 d', '30+ d']
const EDD_BUCKETS = ['1 d', '2-3 d', '4-7 d', '8-15 d', '16-30 d', '30+ d']
const byType = Object.fromEntries(TYPES.map(([k]) => [k, rows.filter(r => r.pendency_type === k)]))

// Courier x ageing pivot for one pendency type, couriers by volume, with a total row.
// Delivery pendency also carries the two signals that say a parcel is actually stuck.
function pivot(type, rs, bucketKey = 'ageing_bucket', buckets = BUCKETS) {
  const extra = type === '3. Delivery pending'
  const line = (label, g) => {
    const o = { Courier: label }
    for (const b of buckets) o[b] = g.filter(r => r[bucketKey] === b).length
    o.Total = g.length
    if (extra) {
      o['EDD missed'] = g.filter(r => r.days_past_edd > 0).length
      o['No scan 3+ d'] = g.filter(r => r.days_since_last_scan >= 3).length
    }
    return o
  }
  const couriers = [...new Set(rs.map(r => r.courier || '(blank)'))]
  const out = couriers.map(c => line(c, rs.filter(r => (r.courier || '(blank)') === c))).sort((a, b) => b.Total - a.Total)
  if (out.length > 1) out.push(line('TOTAL', rs))
  return out
}
const pivots = TYPES.filter(([k]) => k !== '7. Unmapped status' || byType[k].length).map(([k, title, note]) => ({
  k, title, note, rows: byType[k], table: pivot(k, byType[k]), over7: r => r.ageing_days > 7,
}))

// EDD-breached view, placed right after Delivery pending: the same shipments, but only those
// past the courier's EDD and aged by days past EDD rather than days since pickup. It has no
// detail sheet of its own - every row is already on the Delivery pending sheet, filterable
// by edd_breach_bucket - because repeating ~5k rows would push the attachment over the limit.
const eddRows = byType['3. Delivery pending'].filter(r => r.edd_breach_bucket)
pivots.splice(3, 0, {
  k: 'edd', title: 'EDD breached – delivery pending', detailSheet: false,
  note: 'delivery pending already past the courier EDD; ageing = days past EDD',
  rows: eddRows, table: pivot('edd', eddRows, 'edd_breach_bucket', EDD_BUCKETS), over7: r => r.days_past_edd > 7,
})

for (const p of pivots) console.log(`${p.title.padEnd(32)} ${String(p.rows.length).padStart(6)}`)

// ---- workbook ----
// Detail sheets carry only the columns that mean something for that bucket: ~27k rows x every
// column came to 3.8 MB, over Graph's inline-attachment limit. pendency_type is the sheet name.
// Shared blocks, in reading order: identify + where it is now, the attempts, then what it is.
const ID = ['courier', 'ageing_days', 'ageing_bucket', 'awb', 'order_id', 'status', 'cp_stuck_flag',
  'latest_remark', 'current_location', 'last_scan_time', 'days_since_last_scan']
// Product NAME (items) only on the RVP sheets, where the pickup team needs to know what to
// collect; forward sheets carry the SKU alone. items is the widest column and keeping it on
// every sheet pushed the attachment past Graph's inline limit.
const GOODS = ['sku', 'qty', 'invoice_value', 'payment_mode', 'cod_value', 'zone']
const RV_GOODS = ['sku', 'items', 'qty', 'invoice_value', 'payment_mode', 'cod_value', 'zone']
const FWD_PLACE = ['pickup_city', 'drop_city', 'drop_state', 'drop_pincode']        // warehouse -> customer
const REV_PLACE = ['pickup_city', 'pickup_state', 'pickup_pincode', 'drop_city']    // customer -> warehouse
const PICKUP_ATT = ['pickup_attempts', 'pickup_attempt_1', 'pickup_attempt_2', 'pickup_attempt_3']
const OFD = ['ofd_attempts', 'ofd_attempt_1', 'ofd_attempt_2', 'ofd_attempt_3',
  'last_failed_delivery_reason', 'last_failed_delivery_remark']
const COLS = {
  '1. Pickup pending': [...ID, 'awb_created_date', ...PICKUP_ATT, ...GOODS, ...FWD_PLACE, 'channel_name'],
  '2. Hub scan pending': [...ID, 'pickup_time', ...PICKUP_ATT, ...GOODS, ...FWD_PLACE],
  '3. Delivery pending': [...ID, 'pickup_time', 'courier_edd', 'days_past_edd', 'edd_breach_bucket',
    'dest_hub_inscan_time', ...OFD, ...GOODS, ...FWD_PLACE],
  '4. RTO delivery pending': [...ID, 'pickup_time', 'rto_mark_date', 'rto_awb', 'dest_hub_inscan_time',
    ...OFD, ...GOODS, ...FWD_PLACE],
  '5. RVP pickup pending': [...ID, 'awb_created_date', 'return_type', 'rvp_reason', ...PICKUP_ATT,
    'other_rvp_for_order', 'other_rvp_collected', ...RV_GOODS, ...REV_PLACE],
  '6. RVP delivery pending': [...ID, 'awb_created_date', 'pickup_time', 'return_type', 'rvp_reason',
    ...PICKUP_ATT, 'ofd_attempts', 'ofd_attempt_1', 'other_rvp_for_order', ...RV_GOODS, ...REV_PLACE],
  '7. Unmapped status': [...ID, 'awb_created_date', 'pickup_time', 'return_type', ...GOODS, ...FWD_PLACE],
}
// Delivery pendency is ~80% of open shipments and most of it is simply in transit on time, so
// its sheet lists only the parcels needing a chase: EDD missed, no scan for 3+ days, or over a
// week since pickup. The email pivots still count every open shipment.
const actionable = r => r.days_past_edd > 0 || r.days_since_last_scan >= 3 || r.ageing_days > 7
// RVP delivery pendency gets the same treatment (no EDD on reverse legs, so scan + age only).
const TRIMMED = ['3. Delivery pending', '6. RVP delivery pending']
const detail = (k, rs) => (TRIMMED.includes(k) ? rs.filter(actionable) : rs)
const pick = (k, rs) => detail(k, rs).map(r => Object.fromEntries(COLS[k].map(c => [c, r[c] ?? null])))

// One flat table, so every row needs the same columns in the same order. The EDD view's first
// bucket is "1 d" (0 days past EDD is not a breach); it sits in the 0-1 d column, and the row
// label says its ageing is days past EDD.
const summary = pivots.flatMap(p => p.table.map(({ '1 d': d1, ...t }) => ({
  Pendency: p.k === 'edd' ? `${p.title} (ageing = days past EDD)` : p.title,
  Courier: t.Courier,
  ...Object.fromEntries(BUCKETS.map(b => [b, b === '0-1 d' && p.k === 'edd' ? d1 : t[b]])),
  Total: t.Total,
  'EDD missed': t['EDD missed'] ?? null,
  'No scan 3+ d': t['No scan 3+ d'] ?? null,
})))
const fileName = `clickpost_pendency_${today}.xlsx`
const wb = writeWorkbook(fileName, [
  ['Summary', summary],
  ...pivots.filter(p => p.detailSheet !== false).map(p => [p.title.slice(0, 31), pick(p.k, p.rows)]),
])

// ---- email ----
const num = (t) => t.map(r => Object.fromEntries(Object.entries(r).map(([k, v]) => [k, typeof v === 'number' ? fmt(v) : v])))
const right = [...new Set([...BUCKETS, ...EDD_BUCKETS]), 'Total', 'EDD missed', 'No scan 3+ d']
const overview = pivots.map(p => ({
  Pendency: p.title,
  Shipments: fmt(p.rows.length),
  'Over 7 days': fmt(p.rows.filter(p.over7).length),
}))
const sections = pivots.map(p => `
  <h3 style="margin:22px 0 4px;font-size:15px">${p.title} — ${fmt(p.rows.length)}</h3>
  <div style="font-size:12px;color:#666;margin-bottom:6px">${p.note}</div>
  ${p.rows.length ? htmlTable(num(p.table), { right }) : '<div style="font-size:13px">No pending shipments.</div>'}`).join('')

const unmapped = byType['7. Unmapped status']
const unmappedNote = unmapped.length
  ? `<p style="background:#FDECEA;border-left:4px solid #C0392B;padding:8px 12px;font-size:13px">
       <b>New Clickpost status found:</b> ${[...new Set(unmapped.map(r => r.status))].join(', ')}
       (${fmt(unmapped.length)} shipments). These are listed under <i>Unmapped status</i> and are not in any
       pendency bucket until the status is added to the report.</p>`
  : ''
const html = `
  <p>Hi team,</p>
  ${unmappedNote}
  <p>Below is today's <b>Shipment Pendency</b> (${today}) for AWBs created in the last 45 days,
     courier and ageing wise. The AWB-level list for each bucket is attached. For delivery pendency
     and RVP delivery pendency the sheet lists only the shipments that need a chase — EDD missed,
     no scan for 3+ days, or more than 7 days since pickup
     (${fmt(detail('3. Delivery pending', byType['3. Delivery pending']).length)} forward,
     ${fmt(detail('6. RVP delivery pending', byType['6. RVP delivery pending']).length)} RVP).</p>
  ${htmlTable(overview, { right: ['Shipments', 'Over 7 days'] })}
  ${sections}
  <p style="font-size:12px;color:#666;margin-top:18px">
    <b>EDD missed</b> – today is past the courier's expected delivery date.
    <b>No scan 3+ d</b> – no tracking update for 3 or more days.
    In the overview, <b>Over 7 days</b> for EDD breached means more than 7 days past EDD.
    EDD-breached shipments are on the <i>Delivery pending</i> sheet — filter <i>edd_breach_bucket</i>.</p>
  <p>— Data Team</p>`

// --dry-run: save the email body next to the xlsx so it can be checked without sending.
if (opts.dryRun) {
  const preview = fileName.replace(/\.xlsx$/, '.html')
  writeFileSync(join(ROOT, 'exports', preview), html)
  console.log(`Wrote exports/${preview} (email preview)`)
  process.exit(0)
}

const open = rows.length
await sendReport({
  to: opts.to, cc: opts.cc, fileName, wb, html,
  subject: `Shipment Pendency | ${today} | ${fmt(open)} open shipments`,
})
