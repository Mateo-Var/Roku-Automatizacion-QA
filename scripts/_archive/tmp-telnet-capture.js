// Captura telnet temporal para el Agente Player (sesión 2026-09-14).
// Uso: node scripts/tmp-telnet-capture.js <host> <port> <outFile> <maxSeconds>
// Escribe el log crudo incrementalmente a outFile y cierra el socket limpio
// (net.destroy) al llegar a maxSeconds o al recibir SIGTERM/SIGINT -- nunca
// usa timeout+bash (deja sockets huérfanos, ver PROJECT_MEMORY.md).
import net from 'node:net'
import fs from 'node:fs'

const [, , host, portArg, outFile, maxSecArg] = process.argv
const port = Number(portArg)
const maxSec = Number(maxSecArg || 600)

const fd = fs.openSync(outFile, 'a')
const socket = net.connect({ host, port })
socket.setEncoding('utf8')
socket.on('connect', () => console.error(`[capture] connected ${host}:${port}`))
socket.on('data', (chunk) => fs.writeSync(fd, chunk))
socket.on('error', (err) => fs.writeSync(fd, `\n[telnet error] ${err.message}\n`))

function shutdown() {
  try { socket.destroy() } catch {}
  try { fs.closeSync(fd) } catch {}
  console.error('[capture] closed cleanly')
  process.exit(0)
}
process.on('SIGTERM', shutdown)
process.on('SIGINT', shutdown)
setTimeout(shutdown, maxSec * 1000)
