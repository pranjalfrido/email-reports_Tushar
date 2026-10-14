// Runs email-reports/sql/shopify_uc_sync_audit_email.sql (is every Shopify order in Unicommerce?)
// on BigQuery and emails the result as an .xlsx via Microsoft Graph.
//
//   node email-reports/email-uc-sync-audit.mjs --to tushar.g@myfrido.com
//   node email-reports/email-uc-sync-audit.mjs --to a@x.com,b@x.com --cc c@x.com --from 2026-10-01 --until 2026-10-10
//   node email-reports/email-uc-sync-audit.mjs --dry-run        (build the xlsx, don't send)
//
// --from/--until set the Shopify order window; the UC and Clickpost windows follow it and run
// UC_LAG_DAYS past --until, as in the SQL.

import { readFileSync } from 'fs'
import { join } from 'path'
import { SQL_DIR, parseArgs, addDays, queryRows, writeWorkbook, htmlTable, inr, sendReport } from './lib/report-mailer.mjs'

const UC_LAG_DAYS = 7
const opts = parseArgs()

// ---- query, with the three date windows re-pointed ----
let sql = readFileSync(join(SQL_DIR, 'shopify_uc_sync_audit_email.sql'), 'utf8')
const SHOPIFY_RE = /order_date_ist BETWEEN '(\d{4}-\d{2}-\d{2})' AND '(\d{4}-\d{2}-\d{2})'/
const [, sqlFrom, sqlUntil] = sql.match(SHOPIFY_RE)
const lagged = `'${sqlFrom}' AND '${addDays(sqlUntil, UC_LAG_DAYS)}'`
if (sql.split(lagged).length - 1 !== 2) throw new Error(`Expected the UC and Clickpost windows to be ${lagged}`)

const winFrom = opts.from || sqlFrom
const winUntil = opts.until || sqlUntil
sql = sql.replace(SHOPIFY_RE, `order_date_ist BETWEEN '${winFrom}' AND '${winUntil}'`)
         .replaceAll(lagged, `'${winFrom}' AND '${addDays(winUntil, UC_LAG_DAYS)}'`)

console.log(`Auditing Shopify orders ${winFrom} → ${winUntil} (UC/Clickpost to ${addDays(winUntil, UC_LAG_DAYS)}) ...`)
const rows = await queryRows(sql, { stringCols: ['order_id', 'line_item_id'] })
const review = rows.filter(r => r.x_needs_review)
const orders = (rs) => new Set(rs.map(r => r.order_name)).size

const summarise = (rs) => Object.entries(rs.reduce((m, r) => {
  m[r.x_verdict] ??= []; m[r.x_verdict].push(r)
  return m
}, {})).map(([verdict, g]) => ({
  Verdict: verdict,
  Orders: orders(g),
  Lines: g.length,
  'Line value': inr(g.reduce((s, r) => s + (Number(r.final_total_incl_tax) || 0), 0)),
})).sort((a, b) => b.Orders - a.Orders)
const byVerdict = summarise(review).map(({ Verdict, ...v }) => ({ Issue: Verdict.replace(/^HIGHLIGHT - /, ''), ...v }))
const allVerdicts = summarise(rows)

console.log(`${orders(rows)} orders / ${rows.length} lines audited, ${orders(review)} orders / ${review.length} lines need review`)
console.table(allVerdicts)

// ---- workbook ----
// No all-lines sheet: ~90k lines x 120 columns is far over Graph's ~4 MB sendMail limit.
const fileName = `shopify_uc_sync_audit_${winFrom}_to_${winUntil}.xlsx`
const wb = writeWorkbook(fileName, [
  ['Needs Review', review],
  ['Summary', allVerdicts],
])
if (opts.dryRun) process.exit(0)

// ---- email ----
const html = `
  <p>Hi team,</p>
  <p>Attached is the <b>Shopify → Unicommerce sync audit</b> for orders placed
     <b>${winFrom}</b> to <b>${winUntil}</b>.</p>
  <ul>
    <li>Orders audited: <b>${orders(rows).toLocaleString('en-IN')}</b> (${rows.length.toLocaleString('en-IN')} lines)</li>
    <li>Orders needing review: <b>${orders(review).toLocaleString('en-IN')}</b> (${review.length.toLocaleString('en-IN')} lines)</li>
  </ul>
  ${htmlTable(byVerdict, { right: ['Orders', 'Lines', 'Line value'] })}
  <p style="font-size:13px;color:#555">
    <b>missing from UC</b> – Shopify order never reached Unicommerce.<br>
    <b>retail online, not in UC</b> – Retail Store order (not cash &amp; carry) that should ship but isn't in UC.<br>
    Not flagged: retail cash &amp; carry orders and orders tagged ORDER_CANCELLED_CP; coupon SKUs are excluded.
  </p>
  <p>The <i>Needs Review</i> sheet has the line-level detail for every flagged order;
     <i>Summary</i> shows every verdict, including the OK ones.</p>
  <p>— Data Team</p>`

await sendReport({
  to: opts.to, cc: opts.cc, fileName, wb, html,
  subject: `Shopify → UC sync audit | ${winFrom} to ${winUntil} | ${orders(review)} orders to review`,
})
