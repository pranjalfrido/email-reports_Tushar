// Runs email-reports/sql/shopify_cancelled_no_refund.sql on BigQuery and emails the result as an
// .xlsx via Microsoft Graph (see email-reports/lib/report-mailer.mjs).
//
//   node email-reports/email-cancelled-no-refund.mjs --to tushar.g@myfrido.com
//   node email-reports/email-cancelled-no-refund.mjs --to a@x.com,b@x.com --cc c@x.com --from 2026-10-01 --until 2026-10-31
//   node email-reports/email-cancelled-no-refund.mjs --dry-run        (build the xlsx, don't send)

import { readFileSync } from 'fs'
import { join } from 'path'
import { SQL_DIR, parseArgs, rolling30, queryRows, writeWorkbook, htmlTable, inr, sendReport } from './lib/report-mailer.mjs'

const opts = parseArgs()
const defaults = rolling30()

// ---- query ----
let sql = readFileSync(join(SQL_DIR, 'shopify_cancelled_no_refund.sql'), 'utf8')
const WINDOW_RE = /order_date_ist BETWEEN '(\d{4}-\d{2}-\d{2})' AND '(\d{4}-\d{2}-\d{2})'/
const winFrom = opts.from || defaults.from
const winUntil = opts.until || defaults.until
sql = sql.replace(WINDOW_RE, `order_date_ist BETWEEN '${winFrom}' AND '${winUntil}'`)

console.log(`Querying cancelled orders ${winFrom} → ${winUntil} ...`)
const rows = await queryRows(sql)
const review = rows.filter(r => r.needs_review)
const atRisk = review.reduce((s, r) => s + (Number(r.order_total) || 0), 0)
// Needs-review orders with no refund status at all, but a Shopify order note (usually
// "Size edited #MF…" / "#MF…" — the order was re-placed, so the payment may have moved).
const isBlank = (s) => !String(s ?? '').replace(/\|/g, '').trim()
const noStatusWithNote = review.filter(r => isBlank(r.raw_refund_statuses) && !isBlank(r.shopify_note))
console.log(`${rows.length} cancelled prepaid orders, ${review.length} need review, ₹${atRisk.toFixed(0)} at risk, ` +
  `${noStatusWithNote.length} with no refund status but a note`)

const byReason = Object.entries(rows.reduce((m, r) => {
  const k = r.refund_gap_reason || '(none)'
  m[k] ??= { orders: 0, amount: 0 }
  m[k].orders++; m[k].amount += Number(r.order_total) || 0
  return m
}, {})).map(([reason, v]) => ({ refund_gap_reason: reason, orders: v.orders, order_total: Math.round(v.amount) }))
  .sort((a, b) => b.orders - a.orders)

// ---- workbook ----
const fileName = `shopify_cancelled_no_refund_${winFrom}_to_${winUntil}.xlsx`
const wb = writeWorkbook(fileName, [
  ['Needs Review', review],
  ['By Gap Reason', byReason],
  ['All Cancelled Prepaid', rows],
])
if (opts.dryRun) process.exit(0)

// ---- email ----
const reasonTable = byReason.map(r => ({ 'Gap reason': r.refund_gap_reason, Orders: r.orders, 'Order total': inr(r.order_total) }))
const html = `
  <p>Hi team,</p>
  <p>Attached is the list of <b>cancelled prepaid Shopify orders where no refund was triggered</b>
     for orders placed <b>${winFrom}</b> to <b>${winUntil}</b>.</p>
  <ul>
    <li>Cancelled prepaid orders: <b>${rows.length}</b></li>
    <li>Needing review (no successful refund): <b>${review.length}</b></li>
    <li>No refund status, but Shopify note available: <b>${noStatusWithNote.length}</b>
        (mostly “Size/Color edited #MF…” — likely re-placed orders)</li>
  </ul>
  ${htmlTable(reasonTable, { right: ['Orders', 'Order total'] })}
  <p>The <i>Needs Review</i> sheet has the order-level detail, oldest cancellations first.</p>
  <p>— Data Team</p>`

await sendReport({
  to: opts.to, cc: opts.cc, fileName, wb, html,
  subject: `Cancelled orders – refund not triggered | ${winFrom} to ${winUntil} | ${review.length} to review`,
})
