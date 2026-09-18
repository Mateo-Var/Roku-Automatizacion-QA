#!/usr/bin/env node
// Simple telnet log capture: connects to port 8085, writes raw lines to a file.
// Usage: node scripts/telnet-capture.js <output-log-path> [durationSec]
import net from 'node:net'
import fs from 'node:fs'

const HOST = process.env.ROKU_HOST || '192.168.1.34'
const PORT = 8085
const outPath = process.argv[2]
const durationSec = Number(process.argv[3] || 600)

if (!outPath) {
  console.error('Uso: node scripts/telnet-capture.js <output-log-path> [durationSec]')
  process.exit(1)
}

const out = fs.createWriteStream(outPath, { flags: 'a' })
const socket = net.connect(PORT, HOST, () => {
  console.error(`Conectado a telnet ${HOST}:${PORT}, escribiendo a ${outPath}`)
})

socket.on('data', (chunk) => {
  out.write(chunk)
})

socket.on('error', (err) => {
  console.error('Error de socket:', err.message)
})

socket.on('close', () => {
  console.error('Socket cerrado.')
  out.end()
})

setTimeout(() => {
  console.error('Duración alcanzada, cerrando socket limpio.')
  socket.destroy()
  process.exit(0)
}, durationSec * 1000)

process.on('SIGINT', () => {
  socket.destroy()
  process.exit(0)
})
