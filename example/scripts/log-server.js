const http = require('http')
const fs = require('fs')
const path = require('path')
const { execFileSync } = require('child_process')

const PORT = 8099
const WINDOW_SECONDS = 5
const PACKAGE = 'com.illusion.everythingplayer.sabrexample'
const LOG_DIR = path.join(__dirname, '..', 'logs')

const adbPath = process.env.ANDROID_HOME
  ? path.join(process.env.ANDROID_HOME, 'platform-tools', process.platform === 'win32' ? 'adb.exe' : 'adb')
  : 'adb'

const adb = (...args) => execFileSync(adbPath, args, { encoding: 'utf8', maxBuffer: 64 << 20 })

function capture(state) {
  const deviceNow = parseFloat(adb('shell', 'date', '+%s.%N'))
  const since = (deviceNow - WINDOW_SECONDS).toFixed(3)
  const pid = adb('shell', 'pidof', PACKAGE).trim()
  const logs = adb('logcat', '-d', '-v', 'threadtime', '-T', since, ...(pid ? [`--pid=${pid.split(/\s+/)[0]}`] : []))
  const stamp = new Date().toISOString().replace(/[:.]/g, '-')
  const file = path.join(LOG_DIR, `${stamp}.txt`)
  fs.mkdirSync(LOG_DIR, { recursive: true })
  fs.writeFileSync(file, `# app state\n${JSON.stringify(state, null, 2)}\n\n# logcat (last ${WINDOW_SECONDS}s, pid ${pid || 'n/a'})\n${logs}`)
  return file
}

http
  .createServer((req, res) => {
    if (req.method !== 'POST' || req.url !== '/logs') {
      res.writeHead(404).end()
      return
    }
    let body = ''
    req.on('data', (chunk) => (body += chunk))
    req.on('end', () => {
      try {
        const file = capture(body ? JSON.parse(body) : {})
        console.log(`saved ${file}`)
        res.writeHead(200, { 'content-type': 'application/json' }).end(JSON.stringify({ file: path.basename(file) }))
      } catch (e) {
        console.error(e)
        res.writeHead(500, { 'content-type': 'application/json' }).end(JSON.stringify({ error: String(e.message ?? e) }))
      }
    })
  })
  .listen(PORT, () => {
    try {
      adb('reverse', `tcp:${PORT}`, `tcp:${PORT}`)
    } catch (e) {
      console.warn(`adb reverse failed (${e.message}); connect a device and restart`)
    }
    console.log(`log server on :${PORT}, saving to ${LOG_DIR}`)
  })
