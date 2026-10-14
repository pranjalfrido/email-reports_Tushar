// Runs email-reports/sql/uc_order_not_closed.sql (Shopify shipments where the Unicommerce status is
// still open but Clickpost has moved on) on BigQuery and emails the result as an .xlsx.
//
//   node email-reports/email-uc-order-not-closed.mjs --to tushar.g@myfrido.com
//   node email-reports/email-uc-order-not-closed.mjs --to a@x.com,b@x.com --cc c@x.com --from 2026-10-01 --until 2026-10-31
//   node email-reports/email-uc-order-not-closed.mjs --dry-run        (build the xlsx, don't send)
//
// --from/--until set both the Shopify and the UC order windows (the SQL uses the same dates).

import { readFileSync } from 'fs'
import { join } from 'path'
import { SQL_DIR, parseArgs, rolling30, queryRows, writeWorkbook, htmlTable, sendReport } from './lib/report-mailer.mjs'

const opts = parseArgs()
const defaults = rolling30()

// ---- query ----
let sql = readFileSync(join(SQL_DIR, 'uc_order_not_closed.sql'), 'utf8')
const [, sqlFrom, sqlUntil] = sql.match(/order_date_ist BETWEEN '(\d{4}-\d{2}-\d{2})' AND '(\d{4}-\d{2}-\d{2})'/)
const window = `'${sqlFrom}' AND '${sqlUntil}'`
if (sql.split(window).length - 1 !== 2) throw new Error(`Expected the Shopify and UC windows to both be ${window}`)
const winFrom = opts.from || defaults.from
const winUntil = opts.until || defaults.until
sql = sql.replaceAll(window, `'${winFrom}' AND '${winUntil}'`)

console.log(`Checking UC vs Clickpost for Shopify orders ${winFrom} → ${winUntil} ...`)
const rows = await queryRows(sql, { stringCols: ['awb', 'uc_order_id'] })

// Fixed order and wording for the email; any issue type the SQL adds later still shows up.
const ISSUES = {
  MANIFEST_NOT_CLOSED: 'UC at Ready to Ship/Manifested, but the courier has picked up the parcel or gone further',
  UC_NOT_UPDATED_AFTER_DELIVERY: 'UC shows Dispatched/Shipped, but Clickpost says Delivered or RTO-Delivered',
  RTO_NOT_REFLECTED_IN_UC: 'Courier has RTO’d, cancelled or lost the shipment; UC still shows in transit',
  NOT_SCANNED_BY_COURIER_YET: 'UC shows Dispatched/Shipped, but the courier has no pickup scan yet',
  NOT_IN_CLICKPOST: 'AWB exists in UC but Clickpost has no record of it',
  STAGE_GAP_REVIEW: 'Anything else where UC is still open',
}
const groups = rows.reduce((m, r) => { (m[r.issue_type] ??= []).push(r); return m }, {})
const order = [...Object.keys(ISSUES), ...Object.keys(groups).filter(k => !(k in ISSUES))]
const summary = order.filter(k => groups[k]).map(k => ({
  Issue: k,
  AWBs: groups[k].length,
  'Over 7 days open': groups[k].filter(r => r.days_open > 7).length,
  'Oldest (days)': Math.max(...groups[k].map(r => r.days_open ?? 0)),
  Meaning: ISSUES[k] ?? '',
}))
console.log(`${rows.length} open AWBs`)
console.table(summary.map(({ Meaning, ...s }) => s))

// ---- workbook ----
const fileName = `uc_order_not_closed_${winFrom}_to_${winUntil}.xlsx`
const wb = writeWorkbook(fileName, [
  ['Summary', summary],
  ['Order Not Closed', rows],
])
if (opts.dryRun) process.exit(0)

// ---- email ----
const fmt = (n) => n.toLocaleString('en-IN')
const html = `
  <p>Hi team,</p>
  <p>Attached is the <b>Order Not Closed</b> report: Shopify shipments (orders placed
     <b>${winFrom}</b> to <b>${winUntil}</b>) where the Unicommerce status is still open but
     Clickpost shows the parcel has moved on.</p>
  <ul>
    <li>Open AWBs flagged: <b>${fmt(rows.length)}</b></li>
    <li>Manifest not closed: <b>${fmt(groups.MANIFEST_NOT_CLOSED?.length ?? 0)}</b></li>
  </ul>
  ${htmlTable(summary.map(s => ({ ...s, AWBs: fmt(s.AWBs), 'Over 7 days open': fmt(s['Over 7 days open']) })),
              { right: ['AWBs', 'Over 7 days open', 'Oldest (days)'] })}
  <p>The <i>Order Not Closed</i> sheet has one row per AWB, sorted by issue and then oldest first.
     Filter on <i>issue_type</i> to work one bucket at a time.</p>
  <p>— Data Team</p>`

await sendReport({
  to: opts.to, cc: opts.cc, fileName, wb, html,
  subject: `Order not closed – UC vs Clickpost | ${winFrom} to ${winUntil} | ${fmt(rows.length)} AWBs`,
})
