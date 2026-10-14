// Shared plumbing for the emailed BigQuery reports (email-reports/email-*.mjs):
// CLI args, BigQuery -> plain rows, styled xlsx sheets, and Microsoft Graph sendMail.
//
// Needs in .env: OTP_FRIDO_CLIENT_ID, OTP_FRIDO_TENANT_ID, OTP_FRIDO_CLIENT_SECRET, REPORT_MAIL_FROM.
// The Azure app needs the Mail.Send *application* permission (admin-consented).

import { BigQuery } from '@google-cloud/bigquery'
import XLSX from 'xlsx-js-style'
import dotenv from 'dotenv'
import { zipSync, unzipSync } from 'fflate'
import { mkdirSync, writeFileSync } from 'fs'
import { fileURLToPath } from 'url'
import { dirname, join } from 'path'

export const ROOT = join(dirname(fileURLToPath(import.meta.url)), '../..')
export const SQL_DIR = join(dirname(fileURLToPath(import.meta.url)), '../sql')
dotenv.config({ path: join(ROOT, '.env'), quiet: true })

// --to a,b --cc c --from YYYY-MM-DD --until YYYY-MM-DD --dry-run
export function parseArgs() {
  const argv = process.argv.slice(2)
  const arg = (name) => { const i = argv.indexOf(`--${name}`); return i >= 0 ? argv[i + 1] : undefined }
  const list = (s) => (s ? s.split(',').map(x => x.trim()).filter(Boolean) : [])
  const opts = { dryRun: argv.includes('--dry-run'), to: list(arg('to')), cc: list(arg('cc')), from: arg('from'), until: arg('until') }
  if (!opts.dryRun && opts.to.length === 0) { console.error('Pass --to <email>[,<email>] or --dry-run'); process.exit(1) }
  return opts
}

export const addDays = (iso, n) => {
  const d = new Date(iso + 'T00:00:00Z'); d.setUTCDate(d.getUTCDate() + n)
  return d.toISOString().slice(0, 10)
}

// Returns { from, until } for the rolling last-30-days window (yesterday inclusive).
export function rolling30() {
  const ist = new Date(new Date().toLocaleString('en-US', { timeZone: 'Asia/Kolkata' }))
  const yesterday = new Date(ist); yesterday.setDate(yesterday.getDate() - 1)
  const fmt = (d) => d.toISOString().slice(0, 10)
  return { from: fmt(new Date(ist.setDate(ist.getDate() - 30))), until: fmt(yesterday) }
}

// BigQuery DATE/DATETIME/TIMESTAMP come back as { value } wrappers and NUMERIC as Big objects;
// flatten both. ID-like columns stay strings so Excel doesn't round or sci-notate them.
export async function queryRows(sql, { stringCols = ['order_id'] } = {}) {
  const bq = new BigQuery({ keyFilename: join(ROOT, 'sa_key.json'), projectId: 'frido-429506' })
  const [raw] = await bq.query(sql)
  const flat = (k, v) => {
    if (v == null || typeof v !== 'object') return v
    if ('value' in v) return v.value
    return stringCols.includes(k) ? v.toString() : Number(v.toString())
  }
  return raw.map(r => Object.fromEntries(Object.entries(r).map(([k, v]) => [k, flat(k, v)])))
}

const HEADER_STYLE = { font: { bold: true, color: { rgb: 'FFFFFF' } }, fill: { fgColor: { rgb: '1F4E78' } } }
export function sheet(data) {
  const ws = XLSX.utils.json_to_sheet(data.length ? data : [{ note: 'No rows' }])
  const cols = Object.keys(data[0] || { note: '' })
  cols.forEach((_, c) => { const cell = ws[XLSX.utils.encode_cell({ r: 0, c })]; if (cell) cell.s = HEADER_STYLE })
  ws['!cols'] = cols.map(k => ({ wch: Math.min(50, Math.max(k.length, ...data.slice(0, 200).map(r => String(r[k] ?? '').length)) + 2) }))
  ws['!autofilter'] = { ref: ws['!ref'] }
  ws['!freeze'] = { xSplit: 0, ySplit: 1 }
  return ws
}

// SheetJS's own deflate is weak (a 15k-row sheet came out at 4 MB); re-zipping the same
// parts at level 9 gets it to ~1.4 MB, which keeps most reports under Graph's inline limit.
function xlsxBuffer(wb) {
  const raw = XLSX.write(wb, { type: 'buffer', bookType: 'xlsx' })
  return Buffer.from(zipSync(unzipSync(new Uint8Array(raw)), { level: 9 }))
}

// sheets: [[name, rows], ...] -> writes exports/<fileName>, returns the workbook.
export function writeWorkbook(fileName, sheets) {
  const wb = XLSX.utils.book_new()
  for (const [name, rows] of sheets) XLSX.utils.book_append_sheet(wb, sheet(rows), name)
  const outDir = join(ROOT, 'exports')
  mkdirSync(outDir, { recursive: true })
  writeFileSync(join(outDir, fileName), xlsxBuffer(wb))
  console.log(`Wrote exports/${fileName}`)
  return wb
}

export const inr = (n) => '₹' + Math.round(n).toLocaleString('en-IN')

// [{ label: value, ... }] -> simple HTML table matching the xlsx header colour.
export function htmlTable(rows, { right = [] } = {}) {
  if (!rows.length) return ''
  const cols = Object.keys(rows[0])
  const td = (c, v, tag = 'td') =>
    `<${tag} style="padding:4px 10px;${tag === 'td' && right.includes(c) ? 'text-align:right' : ''}">${v ?? ''}</${tag}>`
  return `<table style="border-collapse:collapse;font-size:13px" border="1" bordercolor="#ddd">
    <tr style="background:#1F4E78;color:#fff">${cols.map(c => td(c, c, 'th')).join('')}</tr>
    ${rows.map(r => `<tr>${cols.map(c => td(c, r[c])).join('')}</tr>`).join('')}
  </table>`
}

export async function sendReport({ to, cc = [], subject, html, fileName, wb }) {
  const { OTP_FRIDO_CLIENT_ID, OTP_FRIDO_TENANT_ID, OTP_FRIDO_CLIENT_SECRET } = process.env
  const sender = process.env.REPORT_MAIL_FROM || 'data.team@myfrido.com'
  if (!OTP_FRIDO_CLIENT_ID || !OTP_FRIDO_TENANT_ID || !OTP_FRIDO_CLIENT_SECRET) {
    throw new Error('Missing OTP_FRIDO_* credentials in .env')
  }
  const tokenRes = await fetch(`https://login.microsoftonline.com/${OTP_FRIDO_TENANT_ID}/oauth2/v2.0/token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      client_id: OTP_FRIDO_CLIENT_ID,
      client_secret: OTP_FRIDO_CLIENT_SECRET,
      scope: 'https://graph.microsoft.com/.default',
      grant_type: 'client_credentials',
    }),
  })
  const token = await tokenRes.json()
  if (!tokenRes.ok) throw new Error(`Token error: ${token.error} ${token.error_description}`)

  const graph = async (method, path, body) => {
    const res = await fetch(`https://graph.microsoft.com/v1.0/users/${encodeURIComponent(sender)}${path}`, {
      method,
      headers: { Authorization: `Bearer ${token.access_token}`, 'Content-Type': 'application/json' },
      body: body && JSON.stringify(body),
    })
    if (!res.ok) throw new Error(`Graph ${method} ${path} failed (${res.status}): ${await res.text()}`)
    return res.status === 202 || res.status === 204 ? null : res.json()
  }

  const file = xlsxBuffer(wb)
  const XLSX_MIME = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
  const message = {
    subject,
    body: { contentType: 'HTML', content: `<div style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#222">${html}</div>` },
    toRecipients: to.map(address => ({ emailAddress: { address } })),
    ccRecipients: cc.map(address => ({ emailAddress: { address } })),
  }

  // Graph caps a sendMail request at ~4 MB with attachments inline as base64, so files up to
  // ~2.5 MB go inline (needs Mail.Send only). Larger ones go draft -> upload session -> send,
  // which handles up to 150 MB but also needs the Mail.ReadWrite application permission
  // (not granted to the OTP_FRIDO app as of Oct 2026 — that path returns 403 until it is).
  if (file.length <= 2.5 * 1024 * 1024) {
    message.attachments = [{
      '@odata.type': '#microsoft.graph.fileAttachment', name: fileName, contentType: XLSX_MIME,
      contentBytes: file.toString('base64'),
    }]
    await graph('POST', '/sendMail', { message, saveToSentItems: true })
  } else {
    const draft = await graph('POST', '/messages', message)
    const session = await graph('POST', `/messages/${draft.id}/attachments/createUploadSession`, {
      AttachmentItem: { attachmentType: 'file', name: fileName, size: file.length, contentType: XLSX_MIME },
    })
    const CHUNK = 3 * 1024 * 1024 // must be a multiple of 320 KiB
    for (let start = 0; start < file.length; start += CHUNK) {
      const end = Math.min(start + CHUNK, file.length)
      // The upload URL is pre-authorised; sending the bearer token here is rejected.
      const res = await fetch(session.uploadUrl, {
        method: 'PUT',
        headers: { 'Content-Length': String(end - start), 'Content-Range': `bytes ${start}-${end - 1}/${file.length}` },
        body: file.subarray(start, end),
      })
      if (!res.ok) throw new Error(`Attachment upload failed (${res.status}): ${await res.text()}`)
    }
    await graph('POST', `/messages/${draft.id}/send`)
  }
  console.log(`Sent from ${sender} to ${[...to, ...cc].join(', ')} (${(file.length / 1048576).toFixed(1)} MB attachment)`)
}
