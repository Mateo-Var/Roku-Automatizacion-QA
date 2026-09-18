#!/usr/bin/env node
// Helper CLI para el Agente Player - sesión AC-UL-02/03/04/REG-01.
// Uso:
//   node agent-session.mjs key <KEY>              -- un keypress ECP
//   node agent-session.mjs keys <k1,k2,...>        -- varios keypress, 250ms entre ellos
//   node agent-session.mjs lit <texto>             -- teclea texto literal (Lit_x por char)
//   node agent-session.mjs launch                  -- Home + esperar 1s + launch/dev + esperar 1.5s
//   node agent-session.mjs screenshot <outfile>
//   node agent-session.mjs dump <outfile> <ms>     -- conecta telnet, guarda <ms>, cierra limpio
import net from 'node:net'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import fs from 'node:fs'
import 'dotenv/config'

const execFileAsync = promisify(execFile)
const HOST = process.env.ROKU_HOST
const ECP = process.env.ROKU_ECP_PORT || '8060'
const TELNET = process.env.ROKU_TELNET_PORT || '8085'
const PW = process.env.ROKU_DEV_PASSWORD

async function keypress(key) {
  const res = await fetch(`http://${HOST}:${ECP}/keypress/${encodeURIComponent(key)}`, { method: 'POST' })
  if (!res.ok) throw new Error(`keypress ${key} -> ${res.status}`)
}

async function sleep(ms) { return new Promise(r => setTimeout(r, ms)) }

async function litText(text) {
  for (const ch of text) {
    await keypress(`LIT_${ch}`)
    await sleep(180)
  }
}

async function screenshot(outFile) {
  const submit = await execFileAsync('curl', [
    '--digest', '-u', `rokudev:${PW}`, '--silent', '--show-error', '--fail', '--max-time', '30',
    '-F', 'mysubmit=Screenshot', `http://${HOST}/plugin_inspect`,
  ])
  if (!/Screenshot ok/i.test(submit.stdout)) throw new Error('Screenshot not ok')
  await execFileAsync('curl', [
    '--digest', '-u', `rokudev:${PW}`, '--silent', '--show-error', '--fail', '--max-time', '30',
    `http://${HOST}/pkgs/dev.jpg?time=${Date.now()}`, '-o', outFile,
  ])
  console.log('OK screenshot ->', outFile)
}

async function dump(outFile, ms) {
  await new Promise((resolve, reject) => {
    const out = fs.createWriteStream(outFile, { flags: 'a' })
    const socket = net.connect(Number(TELNET), HOST, () => console.error('telnet conectado'))
    socket.on('data', (c) => out.write(c))
    socket.on('error', (e) => console.error('telnet error', e.message))
    socket.on('close', () => { out.end(); resolve() })
    setTimeout(() => socket.destroy(), Number(ms))
  })
  console.log('OK dump ->', outFile)
}

async function main() {
  const [cmd, a, b] = process.argv.slice(2)
  if (cmd === 'key') { await keypress(a); console.log('OK key', a) }
  else if (cmd === 'keys') {
    for (const k of a.split(',')) { await keypress(k); await sleep(250) }
    console.log('OK keys', a)
  }
  else if (cmd === 'lit') { await litText(a); console.log('OK lit', a) }
  else if (cmd === 'launch') {
    await keypress('Home'); await sleep(1000)
    const res = await fetch(`http://${HOST}:${ECP}/launch/dev`, { method: 'POST' })
    if (!res.ok) throw new Error('launch/dev failed ' + res.status)
    await sleep(1500)
    console.log('OK launch')
  }
  else if (cmd === 'launchdev') {
    const res = await fetch(`http://${HOST}:${ECP}/launch/dev`, { method: 'POST' })
    if (!res.ok) throw new Error('launch/dev failed ' + res.status)
    console.log('OK launchdev')
  }
  else if (cmd === 'screenshot') await screenshot(a)
  else if (cmd === 'dump') await dump(a, b)
  else { console.error('comando desconocido', cmd); process.exit(1) }
}

main().catch((e) => { console.error('ERROR', e.message); process.exit(1) })
