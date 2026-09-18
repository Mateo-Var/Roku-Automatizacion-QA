import net from 'node:net'
import fs from 'node:fs'
const s = net.connect({ host: '192.168.1.186', port: 8085 })
let buf = ''
s.setEncoding('utf8')
s.on('data', (d) => { buf += d })
s.on('error', (e) => { buf += `\n[error] ${e.message}\n` })
setTimeout(() => {
  fs.writeFileSync('reports/azteca/analytics/ad-hoc-2026-09-16/telnet-venga-live2.log', buf)
  console.log('listo, bytes:', buf.length)
  s.destroy()
  process.exit(0)
}, 90000)
