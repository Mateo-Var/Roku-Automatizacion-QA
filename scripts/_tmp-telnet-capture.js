// DEPRECADO (2026-09-17): reemplazado por scripts/roku-console-capture.ps1
// (maneja "Console connection is already in use" con reintentos y exit codes
// claros; este script scratch no lo hace y tiene el host hardcodeado). No se
// borra por si algo lo sigue referenciando puntualmente, pero no usar en
// corridas nuevas.
import net from 'node:net'
import fs from 'node:fs'
const OUT = process.argv[2]
const MS = parseInt(process.argv[3] || '15000', 10)
fs.writeFileSync(OUT, '')
const s = net.connect({ host: '192.168.1.186', port: 8085 })
s.setEncoding('utf8')
s.on('data', (d) => { fs.appendFileSync(OUT, d) })
s.on('error', (e) => { fs.appendFileSync(OUT, `\n[error] ${e.message}\n`) })
console.log('capturando en vivo hacia', OUT, 'por', MS, 'ms')
setTimeout(() => { s.destroy(); process.exit(0) }, MS)
