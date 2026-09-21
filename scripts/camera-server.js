#!/usr/bin/env node
// Servidor de grabación con la cámara real de un celular, sin instalar
// ninguna app -- el celular solo abre una página web (getUserMedia +
// MediaRecorder), y esta PC le manda "empezá"/"paren" por WebSocket con la
// misma lógica de un caso por vez que ya usamos en record-suitest.ps1.
//
// Reemplaza tanto a record-suitest.ps1 (capturaba mi pantalla) como al
// intento con la API de Suitest (bloqueado por cuota de plan) -- acá la
// cámara es 100% real y no depende de ningún tercero ni límite de cuenta.
//
// Uso:
//   node scripts/camera-server.js run                       # arrancar el server (dejar corriendo)
//   node scripts/camera-server.js start <case> <archivo.mp4> # arranca la grabación de un caso
//   node scripts/camera-server.js stop                       # la corta, sube y convierte a mp4
//
// Primer paso real: correr "run" en una terminal aparte, abrir en el
// celular http://192.168.1.30:8091 (misma WiFi que esta PC), apuntar la
// cámara trasera al TV, dejarla ahí. Recién ahí usar start/stop por caso
// desde otra terminal.

import 'dotenv/config'
import http from 'node:http'
import https from 'node:https'
import fs from 'node:fs'
import fsp from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import crypto from 'node:crypto'
import { WebSocketServer } from 'ws'
import { spawn } from 'node:child_process'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const PORT = 8091
const STATE_FILE = path.join(__dirname, '.camera-server.state.json')

// Usuario/contraseña fijos para todo el que entre por el túnel público
// (celular grabando y /view desde la PC) -- protege la URL expuesta por
// Cloudflare Tunnel, que de otra forma quedaría abierta a cualquiera.
const AUTH_USER = process.env.CAMERA_AUTH_USER
const AUTH_PASS = process.env.CAMERA_AUTH_PASS
if (!AUTH_USER || !AUTH_PASS) {
  console.error('Falta CAMERA_AUTH_USER / CAMERA_AUTH_PASS en .env -- ver .env.example')
  process.exit(1)
}

function timingSafeEqual(a, b) {
  const bufA = Buffer.from(a)
  const bufB = Buffer.from(b)
  if (bufA.length !== bufB.length) return false
  return crypto.timingSafeEqual(bufA, bufB)
}

function checkAuth(req) {
  const header = req.headers['authorization'] || ''
  if (!header.startsWith('Basic ')) return false
  let decoded
  try {
    decoded = Buffer.from(header.slice(6), 'base64').toString('utf8')
  } catch {
    return false
  }
  const idx = decoded.indexOf(':')
  if (idx === -1) return false
  const user = decoded.slice(0, idx)
  const pass = decoded.slice(idx + 1)
  return timingSafeEqual(user, AUTH_USER) && timingSafeEqual(pass, AUTH_PASS)
}

function requireAuth(res) {
  res.writeHead(401, { 'WWW-Authenticate': 'Basic realm="Camara QA"' })
  res.end('Auth requerida')
}

// El WebSocket del navegador no permite mandar el header Authorization, así
// que para /ws usamos un token derivado del usuario/contraseña, incrustado
// en el HTML -- y ese HTML solo se sirve después de pasar el Basic Auth de
// arriba, así que el token nunca llega a quien no se autenticó primero.
const WS_TOKEN = crypto.createHash('sha256').update(`${AUTH_USER}:${AUTH_PASS}`).digest('hex')

const PAGE_HTML = `<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Camara QA</title>
<style>
  body{margin:0;background:#111;color:#eee;font-family:sans-serif;display:flex;flex-direction:column;align-items:center;padding:12px}
  video{width:100%;max-width:480px;border-radius:8px;background:#000}
  #status{margin-top:10px;font-size:15px;text-align:center}
  .rec{color:#ff5252;font-weight:bold}
  .idle{color:#8bc34a}
  #zoomBox{width:100%;max-width:480px;margin-top:14px;display:none}
  #zoomBox label{display:flex;justify-content:space-between;font-size:13px;color:#aaa}
  #zoomSlider{width:100%}
  #zoomNote{font-size:12px;color:#888;margin-top:6px;text-align:center}
</style>
</head>
<body>
  <video id="v" autoplay playsinline muted></video>
  <div id="status" class="idle">Conectando...</div>
  <div id="zoomBox">
    <label><span>Zoom</span><span id="zoomVal">1.0x</span></label>
    <input type="range" id="zoomSlider" min="1" max="1" step="0.1" value="1">
  </div>
  <div id="zoomNote"></div>
<script>
let recorder = null
let chunks = []
let currentCase = null
const statusEl = document.getElementById('status')

function setStatus(text, cls) {
  statusEl.textContent = text
  statusEl.className = cls
}

async function start() {
  const stream = await navigator.mediaDevices.getUserMedia({
    video: { facingMode: { ideal: 'environment' }, width: { ideal: 1920 }, height: { ideal: 1080 } },
    audio: false,
  })
  document.getElementById('v').srcObject = stream
  const zoom = setupZoom(stream)
  const applyZoom = zoom.apply

  const ws = new WebSocket('wss://' + location.host + '/?role=phone&token=__WS_TOKEN__')
  ws.onclose = () => { setStatus('Desconectado -- recargá la página', 'rec'); setTimeout(() => location.reload(), 3000) }

  // Manda una foto chica cada ~300ms para que se pueda ver en vivo desde
  // la PC (pestaña /view) -- no es video fluido, es para encuadrar la
  // cámara antes de grabar un caso, no para ver la reproducción en detalle.
  const snapCanvas = document.createElement('canvas')
  snapCanvas.width = 720
  const snapCtx = snapCanvas.getContext('2d')
  setInterval(() => {
    if (ws.readyState !== WebSocket.OPEN) return
    const video = document.getElementById('v')
    if (!video.videoWidth) return
    snapCanvas.height = Math.round(720 * video.videoHeight / video.videoWidth)
    snapCtx.drawImage(video, 0, 0, snapCanvas.width, snapCanvas.height)
    ws.send(JSON.stringify({ event: 'frame', data: snapCanvas.toDataURL('image/jpeg', 0.75) }))
  }, 350)

  ws.onmessage = async (ev) => {
    const msg = JSON.parse(ev.data)
    if (msg.cmd === 'start') {
      currentCase = msg.case
      chunks = []
      recorder = new MediaRecorder(stream, { mimeType: 'video/webm;codecs=vp8' })
      recorder.ondataavailable = (e) => { if (e.data.size > 0) chunks.push(e.data) }
      recorder.onstop = async () => {
        const blob = new Blob(chunks, { type: 'video/webm' })
        setStatus('Subiendo ' + currentCase + '...', 'rec')
        await fetch('/upload/' + encodeURIComponent(currentCase), { method: 'POST', body: blob })
        setStatus('Listo, esperando caso...', 'idle')
        ws.send(JSON.stringify({ event: 'uploaded', case: currentCase }))
      }
      recorder.start()
      setStatus('GRABANDO: ' + currentCase, 'rec')
    } else if (msg.cmd === 'stop') {
      if (recorder && recorder.state !== 'inactive') recorder.stop()
    } else if (msg.cmd === 'setZoom') {
      applyZoom(msg.value)
    }
  }

  // Avisa una sola vez el rango de zoom real de este celular, para que la
  // PC (pestaña /view) pueda dibujar un slider con los límites correctos.
  ws.onopen = () => {
    setStatus('Listo, esperando caso...', 'idle')
    ws.send(JSON.stringify({ event: 'zoomInfo', ...zoom.info }))
  }
}
function setupZoom(stream) {
  const track = stream.getVideoTracks()[0]
  const caps = track.getCapabilities ? track.getCapabilities() : {}
  const box = document.getElementById('zoomBox')
  const slider = document.getElementById('zoomSlider')
  const val = document.getElementById('zoomVal')
  const note = document.getElementById('zoomNote')
  let applyFn

  if (caps.zoom) {
    // Zoom real de hardware/óptico -- lo que ofrece el navegador para esta cámara.
    slider.min = caps.zoom.min
    slider.max = caps.zoom.max
    slider.step = caps.zoom.step || 0.1
    slider.value = track.getSettings().zoom || caps.zoom.min
    val.textContent = slider.value + 'x'
    box.style.display = 'block'
    note.textContent = ''
    applyFn = (v) => {
      v = Math.min(caps.zoom.max, Math.max(caps.zoom.min, Number(v)))
      slider.value = v
      val.textContent = v.toFixed(1) + 'x'
      track.applyConstraints({ advanced: [{ zoom: v }] }).catch(() => {})
    }
    var info = { hasOptical: true, min: caps.zoom.min, max: caps.zoom.max, step: caps.zoom.step || 0.1, value: Number(slider.value) }
  } else {
    // Este navegador/cámara no expone zoom real -- fallback: zoom digital
    // simple agrandando el video con CSS (pierde calidad, pero sirve para encuadrar).
    slider.min = 1
    slider.max = 3
    slider.step = 0.1
    slider.value = 1
    box.style.display = 'block'
    note.textContent = 'Este celular no soporta zoom óptico vía navegador -- esto es zoom digital (recorta imagen)'
    const video = document.getElementById('v')
    applyFn = (v) => {
      v = Math.min(3, Math.max(1, Number(v)))
      slider.value = v
      val.textContent = v.toFixed(1) + 'x'
      video.style.transform = 'scale(' + v + ')'
      video.style.transformOrigin = 'center center'
    }
    var info = { hasOptical: false, min: 1, max: 3, step: 0.1, value: 1 }
  }
  slider.oninput = () => applyFn(slider.value)
  return { apply: applyFn, info }
}

start().catch((e) => setStatus('Error de cámara: ' + e.message, 'rec'))
</script>
</body>
</html>`

const VIEW_HTML = `<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Ver camara</title>
<style>
  body{margin:0;background:#0a0a0a;color:#eee;font-family:sans-serif;display:flex;flex-direction:column;align-items:center;padding:16px}
  img{width:100%;max-width:720px;border-radius:8px;background:#000;image-rendering:auto}
  #status{margin-top:10px;font-size:13px;color:#888}
  #zoomBox{width:100%;max-width:720px;margin-top:14px}
  #zoomBox label{display:flex;justify-content:space-between;font-size:13px;color:#aaa}
  #zoomSlider{width:100%}
  #zoomNote{font-size:12px;color:#888;margin-top:6px;text-align:center}
</style>
</head>
<body>
  <img id="f" alt="esperando imagen del celular...">
  <div id="status">conectando...</div>
  <div id="zoomBox">
    <label><span>Zoom (remoto)</span><span id="zoomVal">--</span></label>
    <input type="range" id="zoomSlider" min="1" max="3" step="0.1" value="1" disabled>
  </div>
  <div id="zoomNote"></div>
<script>
  const img = document.getElementById('f')
  const status = document.getElementById('status')
  const slider = document.getElementById('zoomSlider')
  const zoomVal = document.getElementById('zoomVal')
  const zoomNote = document.getElementById('zoomNote')
  const ws = new WebSocket('wss://' + location.host + '/?role=viewer&token=__WS_TOKEN__')
  let lastFrame = Date.now()
  ws.onopen = () => status.textContent = 'conectado, esperando frames del celular...'
  ws.onclose = () => { status.textContent = 'desconectado -- recargando...'; setTimeout(() => location.reload(), 2000) }
  ws.onmessage = (ev) => {
    const msg = JSON.parse(ev.data)
    if (msg.event === 'frame') {
      img.src = msg.data
      lastFrame = Date.now()
    } else if (msg.event === 'zoomInfo') {
      slider.min = msg.min
      slider.max = msg.max
      slider.step = msg.step
      slider.value = msg.value
      slider.disabled = false
      zoomVal.textContent = Number(msg.value).toFixed(1) + 'x'
      zoomNote.textContent = msg.hasOptical ? '' : 'zoom digital (el celular no expone zoom óptico por navegador)'
    }
  }
  slider.oninput = () => {
    zoomVal.textContent = Number(slider.value).toFixed(1) + 'x'
    ws.send(JSON.stringify({ cmd: 'setZoom', value: Number(slider.value) }))
  }
  setInterval(() => {
    const secs = Math.round((Date.now() - lastFrame) / 1000)
    status.textContent = secs < 3 ? 'en vivo' : 'sin imagen nueva hace ' + secs + 's -- ¿la página del celular sigue abierta?'
  }, 1000)
</script>
</body>
</html>`

async function main() {
  const [, , cmd, ...rest] = process.argv
  if (cmd === 'run') await runServer()
  else if (cmd === 'start') await sendStart(rest[0], rest[1])
  else if (cmd === 'stop') await sendStop()
  else {
    console.error('Uso: run | start <case> <archivo.mp4> | stop')
    process.exit(1)
  }
}

async function runServer() {
  let connectedPhone = null
  let pendingUpload = null // {case, resolve}

  const tlsOptions = {
    key: fs.readFileSync(path.join(__dirname, '.certs', 'key.pem')),
    cert: fs.readFileSync(path.join(__dirname, '.certs', 'cert.pem')),
  }
  const server = https.createServer(tlsOptions, async (req, res) => {
    if (!checkAuth(req)) { requireAuth(res); return }
    if (req.method === 'GET' && req.url === '/') {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' })
      res.end(PAGE_HTML.replace('__WS_TOKEN__', WS_TOKEN))
      return
    }
    if (req.method === 'GET' && req.url === '/view') {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' })
      res.end(VIEW_HTML.replace('__WS_TOKEN__', WS_TOKEN))
      return
    }
    if (req.method === 'POST' && req.url.startsWith('/upload/')) {
      const caseId = decodeURIComponent(req.url.replace('/upload/', ''))
      const chunks = []
      req.on('data', (c) => chunks.push(c))
      req.on('end', async () => {
        const buf = Buffer.concat(chunks)
        const tmpWebm = path.join(__dirname, `.camera-upload-${caseId}.webm`)
        await fsp.writeFile(tmpWebm, buf)
        console.log(`Recibido ${caseId}: ${buf.length} bytes, convirtiendo a mp4...`)
        if (pendingUpload && pendingUpload.case === caseId) {
          pendingUpload.resolve(tmpWebm)
          pendingUpload = null
        }
        res.writeHead(200)
        res.end('ok')
      })
      return
    }
    res.writeHead(404)
    res.end()
  })

  const viewers = new Set()
  let lastZoomInfo = null
  const wss = new WebSocketServer({
    server,
    verifyClient: (info, cb) => {
      const token = new URL(info.req.url, 'https://x').searchParams.get('token')
      cb(!!token && timingSafeEqual(token, WS_TOKEN))
    },
  })
  wss.on('connection', (ws, req) => {
    const role = new URL(req.url, 'https://x').searchParams.get('role')
    if (role === 'viewer') {
      viewers.add(ws)
      console.log('Visor conectado (PC).')
      if (lastZoomInfo) ws.send(JSON.stringify({ event: 'zoomInfo', ...lastZoomInfo }))
      ws.on('close', () => viewers.delete(ws))
      ws.on('message', (raw) => {
        const msg = JSON.parse(raw.toString())
        if (msg.cmd === 'setZoom' && connectedPhone) {
          connectedPhone.send(JSON.stringify({ cmd: 'setZoom', value: msg.value }))
        }
      })
      return
    }
    console.log('Celular conectado.')
    connectedPhone = ws
    ws.on('close', () => { console.log('Celular desconectado.'); if (connectedPhone === ws) connectedPhone = null })
    ws.on('message', (raw) => {
      const msg = JSON.parse(raw.toString())
      if (msg.event === 'uploaded') console.log(`Confirmado: ${msg.case} subido.`)
      else if (msg.event === 'frame') {
        for (const v of viewers) if (v.readyState === 1) v.send(raw.toString())
      } else if (msg.event === 'zoomInfo') {
        lastZoomInfo = msg
        for (const v of viewers) if (v.readyState === 1) v.send(raw.toString())
      }
    })
  })

  // Control local: este mismo proceso "run" escucha comandos de start/stop
  // vía un socket de control simple (archivo de cola), para que las
  // invocaciones separadas "start"/"stop" del CLI puedan pedirle acciones.
  const controlServer = http.createServer(async (req, res) => {
    if (req.method === 'POST' && req.url === '/__control/start') {
      const body = await readBody(req)
      const { case: caseId, outFile } = JSON.parse(body)
      if (!connectedPhone) { res.writeHead(503); res.end('no hay celular conectado'); return }
      pendingUpload = { case: caseId, resolve: null }
      const uploadPromise = new Promise((resolve) => { pendingUpload.resolve = resolve })
      global.__pending = global.__pending || {}
      global.__pending[caseId] = { outFile, uploadPromise }
      connectedPhone.send(JSON.stringify({ cmd: 'start', case: caseId }))
      res.writeHead(200)
      res.end('ok')
      return
    }
    if (req.method === 'POST' && req.url === '/__control/stop') {
      const body = await readBody(req)
      const { case: caseId } = JSON.parse(body)
      if (!connectedPhone) { res.writeHead(503); res.end('no hay celular conectado'); return }
      connectedPhone.send(JSON.stringify({ cmd: 'stop' }))
      const pending = (global.__pending || {})[caseId]
      if (!pending) { res.writeHead(404); res.end('caso no encontrado'); return }
      const tmpWebm = await pending.uploadPromise
      await remuxToMp4(tmpWebm, pending.outFile)
      await fsp.rm(tmpWebm, { force: true })
      res.writeHead(200)
      res.end('ok')
      return
    }
    res.writeHead(404)
    res.end()
  })

  server.listen(PORT, () => console.log(`Servidor de cámara en http://0.0.0.0:${PORT} -- abrí esto en el celular (misma WiFi)`))
  controlServer.listen(PORT + 1, '127.0.0.1', () => console.log(`Control local en 127.0.0.1:${PORT + 1}`))
}

function readBody(req) {
  return new Promise((resolve) => {
    const chunks = []
    req.on('data', (c) => chunks.push(c))
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')))
  })
}

function remuxToMp4(webmFile, mp4File) {
  return new Promise((resolve, reject) => {
    fs.mkdirSync(path.dirname(mp4File), { recursive: true })
    const p = spawn('ffmpeg', ['-y', '-i', webmFile, '-c:v', 'libx264', '-pix_fmt', 'yuv420p', mp4File])
    p.on('close', (code) => (code === 0 ? resolve() : reject(new Error('ffmpeg exit ' + code))))
  })
}

async function sendStart(caseId, outFile) {
  if (!caseId || !outFile) {
    console.error('Uso: node scripts/camera-server.js start <case> <archivo.mp4>')
    process.exit(1)
  }
  const res = await fetch(`http://127.0.0.1:${PORT + 1}/__control/start`, {
    method: 'POST',
    body: JSON.stringify({ case: caseId, outFile: path.resolve(outFile) }),
  })
  if (!res.ok) {
    console.error('Error:', await res.text())
    process.exit(1)
  }
  await fsp.writeFile(STATE_FILE, JSON.stringify({ case: caseId, outFile }))
  console.log(`Grabando ${caseId} (cámara real del celular) -> ${outFile}`)
}

async function sendStop() {
  let state
  try {
    state = JSON.parse(await fsp.readFile(STATE_FILE, 'utf8'))
  } catch {
    console.error('No hay grabación en curso (falta .camera-server.state.json)')
    process.exit(1)
  }
  const res = await fetch(`http://127.0.0.1:${PORT + 1}/__control/stop`, {
    method: 'POST',
    body: JSON.stringify({ case: state.case }),
  })
  if (!res.ok) {
    console.error('Error:', await res.text())
    process.exit(1)
  }
  await fsp.rm(STATE_FILE, { force: true })
  console.log(`Listo: ${state.outFile}`)
}

main().catch((e) => { console.error(e); process.exit(1) })
