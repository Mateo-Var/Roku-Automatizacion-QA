#!/usr/bin/env node
// Fase 1 — Device Runner mínimo.
//
// Qué hace: para cada escenario del YAML dado, abre captura de telnet log
// (puerto 8085) ANTES de tocar nada, ejecuta los keypress/launch que el
// escenario declara, toma una captura de pantalla al final si el escenario
// pide `visual_check`, y deja todo (log crudo + screenshot + metadata) en
// reports/<timestamp>/<scenario-id>/.
//
// Espera de eventos, no de tiempo: en vez de `sleep` fijos entre pasos,
// esta versión espera a que aparezcan patrones reales en el log (ver
// LOG_PATTERNS) antes de seguir — igual que un QA humano espera a ver que
// algo pasó en pantalla, no cuenta segundos a ciegas. Esto es clave porque
// el botón "Next Episode"/"Up Next" vive dentro del Player SDK (.pkg
// cerrado, NO en ott-next-core-roku-tv) y no podemos instrumentarlo
// nosotros con un id propio -- pero SÍ podemos detectar con certeza cuándo
// aparece y cuándo termina de cargar el siguiente episodio observando el
// log que el SDK ya emite.
//
// Todavía NO hace routing (Fase 3) ni clasificación de severidad completa
// (Fase 2) — corre siempre la batería completa del YAML, pero ya deja
// marcado en meta.json si detectó el patrón del bug conocido
// (SC-PLAYER-BUG-01, ver scenarios/clients/azteca/scenarios/player/scenarios.yaml)
// durante la corrida.
//
// Desde 2026-09-15 los escenarios viven repartidos por área, y desde
// 2026-09-18 además por cliente: scenarios/clients/<cliente>/scenarios/<area>/scenarios.yaml
// (ver scenarios/clients/README.md y scenarios/shared/README.md) -- este
// script sigue siendo genérico, recibe la ruta al YAML como argumento, no
// le importa dónde esté.
//
// Requiere: ROKU_HOST y ROKU_DEV_PASSWORD en .env (ver .env.example).
// Nunca commitear .env con valores reales.

import 'dotenv/config'
import fs from 'node:fs/promises'
import path from 'node:path'
import net from 'node:net'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import yaml from 'js-yaml'

const execFileAsync = promisify(execFile)

const ROKU_HOST = process.env.ROKU_HOST
const ROKU_DEV_PASSWORD = process.env.ROKU_DEV_PASSWORD
const ECP_PORT = process.env.ROKU_ECP_PORT || '8060'
const TELNET_PORT = process.env.ROKU_TELNET_PORT || '8085'

if (!ROKU_HOST) {
  console.error('Falta ROKU_HOST — copia .env.example a .env y complétalo.')
  process.exit(1)
}

// --- ECP: control remoto real sobre el Roku (no requiere auth) ---
// Docs: https://developer.roku.com/docs/developer-program/dev-tools/external-control-api.md
async function ecpKeypress(key) {
  const res = await fetch(`http://${ROKU_HOST}:${ECP_PORT}/keypress/${encodeURIComponent(key)}`, { method: 'POST' })
  if (!res.ok) throw new Error(`ECP keypress ${key} -> HTTP ${res.status}`)
}

async function ecpLaunch(channelId = 'dev', params = {}) {
  const qs = new URLSearchParams(params).toString()
  const url = `http://${ROKU_HOST}:${ECP_PORT}/launch/${channelId}${qs ? `?${qs}` : ''}`
  const res = await fetch(url, { method: 'POST' })
  if (!res.ok) throw new Error(`ECP launch -> HTTP ${res.status}`)
}

// --- Screenshot: puerto 80 (instalador), NO el 8060 de ECP. Requiere Digest
// Auth con la contraseña de developer mode. NO hace falta ningún ajuste de
// "Screen Capture" en Developer Options -- ese toggle no existe como tal en
// versiones recientes de Roku OS (confirmado contra .186, software 15.3.4).
//
// El cuelgue que se veía en el smoke test del 2026-09-11 era un bug propio,
// no del device (confirmado 2026-09-14 leyendo el form real que sirve
// /plugin_inspect):
//   1) el campo del form es `mysubmit` en minúscula, no `mySubmit`.
//   2) el form es multipart (`enctype=multipart/form-data`), no urlencoded
//      -- con Content-Length:0 y sin body el Roku se queda esperando el
//      resto del payload multipart que nunca llega, de ahí el cuelgue.
//   3) hace falta que el canal dev esté en FOREGROUND -- si está en el
//      launcher del sistema (Home), el endpoint responde rápido pero con
//      "Screenshot not ok" en vez de generar el jpg.
// Con esos tres fixes responde "Screenshot ok" y sirve el archivo en
// /pkgs/dev.jpg (hay que descargarlo aparte, con la misma auth).
//
// LIMITACIÓN REAL DE LA PLATAFORMA (no es un bug nuestro, confirmado con
// evidencia): esto captura la UI del canal sideloaded, pero NUNCA el frame
// de video en reproducción -- el área de video sale negra (protección de
// contenido a nivel de sistema). Sirve perfecto para Home/EPG/ShowPage/
// menús/overlays de error, pero NO sirve para validar visualmente "se ve
// bien el video". Subtítulos/captions sobre el video SÍ se capturan.
// Nota (2026-09-17): scripts/roku-screenshot.ps1 hace el mismo llamado
// (mysubmit=Screenshot vía plugin_inspect + descarga de /pkgs/dev.jpg con
// digest auth) como script standalone de PowerShell, útil para capturas
// sueltas fuera del pipeline del Agente Player. No reemplaza a esta función:
// device-runner.js la sigue usando integrada al flujo Node de este proyecto.
async function screenshot(outFile) {
  if (!ROKU_DEV_PASSWORD) {
    console.warn('  (sin ROKU_DEV_PASSWORD -> se omite captura de pantalla)')
    return false
  }
  const submitRes = await execFileAsync('curl', [
    '--digest', '-u', `rokudev:${ROKU_DEV_PASSWORD}`,
    '--silent', '--show-error', '--fail', '--max-time', '30',
    '-F', 'mysubmit=Screenshot',
    `http://${ROKU_HOST}/plugin_inspect`,
  ])
  if (!/Screenshot ok/i.test(submitRes.stdout)) {
    throw new Error('Screenshot not ok -- ¿el canal dev está en foreground? (no en el launcher/Home)')
  }
  await execFileAsync('curl', [
    '--digest', '-u', `rokudev:${ROKU_DEV_PASSWORD}`,
    '--silent', '--show-error', '--fail', '--max-time', '30',
    `http://${ROKU_HOST}/pkgs/dev.jpg?time=${Date.now()}`,
    '-o', outFile,
  ])
  return true
}

// --- Telnet debug console: todo lo que pasa por Library/logs/Logger.brs ---
// A diferencia de la v1, el buffer queda accesible EN VIVO (getBuffer) para
// que waitForPattern() pueda observarlo mientras la captura sigue corriendo,
// no solo al final.
function startLogCapture() {
  let buffer = ''
  const socket = net.connect({ host: ROKU_HOST, port: Number(TELNET_PORT) })
  socket.setEncoding('utf8')
  socket.on('data', (chunk) => { buffer += chunk })
  socket.on('error', (err) => { buffer += `\n[telnet error] ${err.message}\n` })
  return {
    getBuffer: () => buffer,
    stop: () => {
      socket.destroy()
      return buffer
    },
  }
}

// Patrones reales observados en telnet.log (ver PROJECT_MEMORY.md, smoke
// tests del 2026-09-11) que sustituyen la necesidad de un id explícito en
// el botón "Next Episode" -- no podemos instrumentar el Player SDK (.pkg
// cerrado), pero su log ya es lo bastante rico para inferir el estado.
const LOG_PATTERNS = {
  appReady: /MainScreen : onLoadStatusChanged : loadStatus : ready/,
  playerLoaded: /player_loaded/,
  upNextAppearing: /UpnextOverlay/i,
  parseJsonBug: /ParseJSON: Unknown identifier/,
  emptyEpisodeIdRequest: /episode\/\.json/, // el bug SC-PLAYER-BUG-01: id vacío entre / y .json
}

// Espera (con timeout) a que un patrón aparezca en el log capturado desde
// AHORA en adelante -- no re-matchea lo que ya estaba en el buffer antes de
// llamar a esta función, para no confundir un evento viejo con uno nuevo.
function waitForPattern(capture, pattern, timeoutMs = 8000, pollMs = 200) {
  const startLen = capture.getBuffer().length
  const deadline = Date.now() + timeoutMs
  return new Promise((resolve) => {
    const tick = () => {
      const buf = capture.getBuffer().slice(startLen)
      const match = buf.match(pattern)
      if (match) return resolve({ matched: true, text: match[0] })
      if (Date.now() >= deadline) return resolve({ matched: false, text: null })
      setTimeout(tick, pollMs)
    }
    tick()
  })
}

// --- Traducción de pasos declarados en YAML a acciones ECP concretas ---
// Los `steps` de scenarios/*.yaml hoy son texto libre pensado para un QA
// humano (Fase 0). Este mapeo cubre las acciones mecánicas comunes; lo que
// no matchee ningún patrón se registra como "manual" en el reporte para que
// un humano lo ejecute mientras se define su automatización (Fase 1 -> 1.1).
const KEY_ALIASES = {
  'lanzar el canal': () => ecpLaunch('dev'),
  home: () => ecpKeypress('Home'),
  'entrar': () => ecpKeypress('Select'), // "entrar al show/episodio" = Select sobre lo enfocado
  'seleccionar': () => ecpKeypress('Select'),
  'atras': () => ecpKeypress('Back'),
  'atrás': () => ecpKeypress('Back'),
  'bajar': () => ecpKeypress('Down'),
  arriba: () => ecpKeypress('Up'),
  abajo: () => ecpKeypress('Down'),
  izquierda: () => ecpKeypress('Left'),
  derecha: () => ecpKeypress('Right'),
  play: () => ecpKeypress('Play'),
  pausa: () => ecpKeypress('Play'), // Play alterna play/pause en Roku
}

// Después de ejecutar un paso, decide qué esperar según lo que el paso
// dice que debería pasar -- en vez de un sleep fijo igual para todos.
// Si nada matchea (o se agota el timeout), sigue de todos modos: esto es
// "esperar mejor", no "bloquear para siempre".
//
// NOTA: el paso "lanzar el canal" NO se maneja acá -- se maneja aparte en
// runScenario(), porque requiere abrir la conexión de telnet DESPUÉS del
// keypress de lanzamiento, no antes (ver nota en runScenario).
async function waitAfterStep(stepText, capture) {
  const normalized = stepText.toLowerCase()
  if (normalized.includes('siguiente episodio') || normalized.includes('next episode') || normalized.includes('up next')) {
    const r = await waitForPattern(capture, LOG_PATTERNS.upNextAppearing, 20000)
    console.log(r.matched ? '  (Up Next detectado en log)' : '  (timeout esperando Up Next, sigo igual)')
    return
  }
  // Solo "seleccionar episodio"/"reproducir" disparan una carga real del
  // player. "Pausar con Play"/"Reanudar con Play" también contienen la
  // palabra "play" pero NO cargan nada nuevo -- iban por error a esta
  // misma espera y siempre hacían timeout (bug real, visto 2026-09-11).
  if (normalized.includes('seleccionar episodio') || normalized.includes('reproduc')) {
    const r = await waitForPattern(capture, LOG_PATTERNS.playerLoaded, 8000)
    console.log(r.matched ? '  (player_loaded detectado en log)' : '  (timeout esperando player_loaded, sigo igual)')
    return
  }
  await new Promise((r) => setTimeout(r, 800)) // fallback: pasos sin patrón conocido (incluye navegación y pausa/reanudar)
}

async function runStepBestEffort(stepText, manualSteps) {
  const normalized = stepText.toLowerCase()
  const match = Object.keys(KEY_ALIASES).find((k) => normalized.includes(k))
  if (match) {
    await KEY_ALIASES[match]()
    return true
  }
  manualSteps.push(stepText)
  return false
}

function isLaunchStep(stepText) {
  const normalized = stepText.toLowerCase()
  return normalized.includes('lanzar el canal') || normalized.includes('cold start')
}

async function runScenario(scenario, runDir) {
  const scDir = path.join(runDir, scenario.id)
  await fs.mkdir(scDir, { recursive: true })

  console.log(`\n▶ ${scenario.id} — ${scenario.title}`)
  const manualSteps = []
  const startedAt = new Date().toISOString()
  // Se abre más abajo -- ver por qué el orden importa en el caso del
  // lanzamiento, justo debajo.
  let capture = null

  for (const step of scenario.steps ?? []) {
    try {
      if (isLaunchStep(step)) {
        // Dos bugs reales encontrados y corregidos acá (2026-09-11):
        // 1) Si el socket de telnet se conecta ANTES de relanzar el canal,
        //    el Roku deja de alimentar datos nuevos después del dump
        //    inicial -- el socket queda "vivo" pero mudo. Fix: conectar
        //    DESPUÉS del keypress de lanzamiento, no antes.
        // 2) Si el canal YA está corriendo (por una sesión previa), llamar
        //    a /launch de nuevo puede ser un no-op -- Roku solo le da foco
        //    sin re-ejecutar Main(), así que nunca aparecen líneas de boot
        //    frescas y el log capturado queda con contenido viejo de la
        //    sesión anterior. Fix: forzar un cold start real saliendo
        //    primero al launcher del sistema (Home) y lanzando desde ahí.
        await ecpKeypress('Home')
        await new Promise((r) => setTimeout(r, 1000))
        await ecpLaunch('dev')
        console.log('  -> lanzar el canal (cold start forzado vía Home)')
        await new Promise((r) => setTimeout(r, 1500)) // deja que el relanzamiento arranque antes de conectar
        capture = startLogCapture()
        const r = await waitForPattern(capture, LOG_PATTERNS.appReady, 15000)
        console.log(r.matched ? '  (app lista: loadStatus=ready detectado)' : '  (timeout esperando boot, sigo igual)')
        continue
      }
      if (!capture) capture = startLogCapture() // escenario que no arranca con un lanzamiento
      const executed = await runStepBestEffort(step, manualSteps)
      if (executed) await waitAfterStep(step, capture)
    } catch (err) {
      console.error(`  ⚠ paso falló: "${step}" -> ${err.message}`)
    }
  }
  if (!capture) capture = startLogCapture() // escenario sin pasos ejecutables (todo manual)

  let screenshotTaken = false
  if (scenario.visual_check) {
    try {
      screenshotTaken = await screenshot(path.join(scDir, 'screenshot.jpg'))
    } catch (err) {
      console.error(`  ⚠ screenshot falló: ${err.message}`)
    }
  }

  const rawLog = capture.stop()
  await fs.writeFile(path.join(scDir, 'telnet.log'), rawLog, 'utf8')

  // Marca automática del bug conocido SC-PLAYER-BUG-01 si apareció durante
  // esta corrida -- ya no hace falta que un humano vuelva a leer el log a
  // mano para notarlo.
  const knownBugHit = LOG_PATTERNS.emptyEpisodeIdRequest.test(rawLog) || LOG_PATTERNS.parseJsonBug.test(rawLog)

  const meta = {
    id: scenario.id,
    title: scenario.title,
    area: scenario.area,
    severity: scenario.severity,
    startedAt,
    finishedAt: new Date().toISOString(),
    screenshotTaken,
    manualStepsPending: manualSteps, // lo que este runner aún no sabe automatizar
    knownBugDetected: knownBugHit ? 'SC-PLAYER-BUG-01' : null,
    // Fase 2 (Log/Visual Auditor) consume telnet.log + logs_watch de scenarios/*.yaml
    // para clasificar severidad completa. Este runner ya adelanta la detección
    // del bug conocido, pero el veredicto fino sigue pendiente de esa fase.
    verdict: 'PENDING_AUDIT',
  }
  await fs.writeFile(path.join(scDir, 'meta.json'), JSON.stringify(meta, null, 2), 'utf8')

  if (manualSteps.length) {
    console.log(`  (${manualSteps.length} paso(s) sin automatizar aún, ver meta.json)`)
  }
  if (knownBugHit) {
    console.log('  🔴 SC-PLAYER-BUG-01 detectado en esta corrida (episode/.json con id vacío + ParseJSON error)')
  }
}

async function main() {
  const yamlPath = process.argv[2]
  if (!yamlPath) {
    console.error('Uso: node scripts/device-runner.js scenarios/clients/<cliente>/scenarios/<area>/scenarios.yaml')
    process.exit(1)
  }

  const scenarios = yaml.load(await fs.readFile(yamlPath, 'utf8'))
  const runId = new Date().toISOString().replace(/[:.]/g, '-')
  const runDir = path.join('reports', runId)
  await fs.mkdir(runDir, { recursive: true })

  console.log(`Roku QA — corriendo ${scenarios.length} escenario(s) de ${yamlPath} contra ${ROKU_HOST}`)
  console.log(`Reporte en ${runDir}/`)

  for (const scenario of scenarios) {
    await runScenario(scenario, runDir)
  }

  console.log(`\nListo. Evidencia cruda en ${runDir}/ — pendiente de Fase 2 (Log/Visual Auditor) para veredicto.`)
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
