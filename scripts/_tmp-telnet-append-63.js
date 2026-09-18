// Scratch: append-only telnet capture against 192.168.1.63:8085, does NOT truncate existing log.
import net from 'node:net'
import fs from 'node:fs'
const OUT = process.argv[2]
const MS = parseInt(process.argv[3] || '600000', 10)
const s = net.connect({ host: '192.168.1.63', port: 8085 })
s.setEncoding('utf8')
s.on('data', (d) => { fs.appendFileSync(OUT, d) })
s.on('error', (e) => { fs.appendFileSync(OUT, `\n[error] ${e.message}\n`) })
s.on('connect', () => { fs.appendFileSync(OUT, `\n[connected ${new Date().toISOString()}]\n`) })
console.log('capturando en vivo hacia', OUT, 'por', MS, 'ms')
setTimeout(() => { s.destroy(); process.exit(0) }, MS)
