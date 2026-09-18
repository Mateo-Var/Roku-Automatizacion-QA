// Captura en vivo, escribe cada chunk al archivo de inmediato (no espera
// al final) -- así si el proceso se mata en cualquier momento, el archivo
// ya tiene todo lo capturado hasta ese punto.
import net from 'node:net'
import fs from 'node:fs'

const OUT = 'reports/azteca/analytics/ad-hoc-2026-09-16/telnet-live.log'
fs.writeFileSync(OUT, '') // arrancar limpio

const s = net.connect({ host: '192.168.1.186', port: 8085 })
s.setEncoding('utf8')
s.on('data', (d) => {
  fs.appendFileSync(OUT, d)
})
s.on('error', (e) => {
  fs.appendFileSync(OUT, `\n[error] ${e.message}\n`)
})
console.log('capturando en vivo hacia', OUT)
