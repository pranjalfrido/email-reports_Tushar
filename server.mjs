// Cloud Run HTTP wrapper — runs all 3 reports on GET /, then returns 200.
// GCP credentials are passed as GCP_CREDENTIALS_B64 (base64 JSON) and written
// to sa_key.json so the BigQuery client can pick them up.

import http from 'http'
import { writeFileSync } from 'fs'
import { spawnSync } from 'child_process'

// Write sa_key.json from env so BigQuery client can find it.
const credsB64 = process.env.GCP_CREDENTIALS_B64
if (!credsB64) { console.error('GCP_CREDENTIALS_B64 not set'); process.exit(1) }
writeFileSync('sa_key.json', Buffer.from(credsB64, 'base64'))

const TO    = process.env.EMAIL_TO   || ''
const FROM  = process.env.FROM_EMAIL || 'reports@myfrido.com'

// Propagate mail env vars that report-mailer.mjs reads from process.env / .env.
process.env.REPORT_MAIL_FROM = FROM

const SCRIPTS = [
  'email-cancelled-no-refund.mjs',
  'email-uc-sync-audit.mjs',
  'email-uc-order-not-closed.mjs',
]

async function runReports() {
  for (const script of SCRIPTS) {
    console.log(`\n=== Running ${script} ===`)
    const result = spawnSync('node', [script, '--to', TO], {
      stdio: 'inherit',
      env: { ...process.env },
    })
    if (result.status !== 0) throw new Error(`${script} exited with code ${result.status}`)
  }
}

const server = http.createServer(async (req, res) => {
  if (req.method !== 'GET' && req.method !== 'POST') {
    res.writeHead(405).end('Method not allowed')
    return
  }
  console.log(`${new Date().toISOString()} — trigger received, running reports...`)
  try {
    await runReports()
    console.log('All 3 reports sent successfully.')
    res.writeHead(200, { 'Content-Type': 'text/plain' }).end('OK — all 3 reports sent\n')
  } catch (err) {
    console.error('Report run failed:', err.message)
    res.writeHead(500, { 'Content-Type': 'text/plain' }).end(`Error: ${err.message}\n`)
  }
})

server.listen(Number(process.env.PORT) || 8080, () => {
  console.log(`Server listening on port ${process.env.PORT || 8080}`)
})
