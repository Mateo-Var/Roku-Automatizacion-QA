#!/usr/bin/env node
// Agente de avance inteligente hasta cerca del final de un episodio (de
// cualquier duración), sin pasarse.
//
// Historia: la v1 de este script intentaba INFERIR el nivel de scrub
// midiendo velocidad observada, pero nunca confirmaba con Select mientras
// escalaba -- se quedaba acumulando toques de Fwd sin comprometerlos, así
// que en la práctica no aceleraba de verdad. El Agente Player (subagente
// autónomo, sesión 2026-09-11) validó a mano, en 3 corridas reales contra
// el device, una tabla escalonada que SÍ funciona de forma repetible:
// escalar con toques discretos rápidos hasta un nivel, sostenerlo unos
// segundos, y CONFIRMAR con Select antes de volver a medir. Esta v2
// implementa exactamente esa tabla ya probada, en vez de inferir nada.
//
// Tabla validada (ver PROJECT_MEMORY.md, sección "Sesión 2026-09-11
// (Agente Player)"):
//   restante > 20 min: nivel x5 (5 toques rápidos + sostener ~5s + Select)
//   restante > 15 min: nivel x3 (3 toques rápidos + sostener ~3s + Select)
//   restante > 10 min: nivel x2 (2 toques rápidos + sostener ~2s + Select)
//   restante > ~2 min: nivel x1 (1 solo toque + sostener ~1s + Select, de a
//     uno -- el sostén mínimo es necesario, ver fix de 2026-09-11 más abajo)
//   restante <= ~2 min: NO TOCAR NADA MÁS -- dejar correr en tiempo real
//     hasta el final natural. Los botones "Next Episode"/Up Next aparecen
//     recién a ~5s del final, no antes.
//
// También hallazgo relevante de esa sesión: los mid-roll ads re-ubican la
// posición a un punto fijo al terminar (RAFPlayerTask: mid-roll finished,
// seek to <N>) -- eso explica buena parte de la "no linealidad" del
// avance; no es solo el nivel de scrub acumulado.
//
// Uso: node scripts/smart-seek-agent.js <ruta-al-telnet.log>
import fs from 'node:fs/promises'

const HOST = process.env.ROKU_HOST || '192.168.1.34'
const STOP_TOUCHING_THRESHOLD = 120 // por debajo de esto, cero toques -- dejar correr solo
const POLL_WAIT_MS = 8000            // el log de posición se refresca cada ~30-60s reales; no leer más rápido que esto
const MAX_TICKS = 80

async function ecpKeypress(key) {
  try {
    await fetch(`http://${HOST}:8060/keypress/${key}`, { method: 'POST' })
  } catch { /* transitorio, se reintenta en el próximo tick */ }
}

async function pressRepeat(key, times) {
  for (let i = 0; i < times; i++) {
    await ecpKeypress(key)
    await new Promise((r) => setTimeout(r, 150)) // rápido, para escalar el nivel de scrub, no toques sueltos espaciados
  }
}

async function readLog(logPath) {
  return fs.readFile(logPath, 'utf8')
}

function lastPlaybackId(content) {
  const matches = [...content.matchAll(/playback_id:\s*"([A-Za-z0-9]+)"/g)]
  return matches.length ? matches[matches.length - 1][1] : null
}

function lastPositionSeconds(content) {
  // Solo lo que aparece DESPUÉS del último playback_id, para no confundir
  // con la cola de un episodio anterior.
  const idx = content.lastIndexOf('playback_id:')
  if (idx === -1) return null
  const tail = content.slice(idx)
  const matches = [...tail.matchAll(/^ {4}position: (\d+)/gm)]
  if (!matches.length) return null
  return Number(matches[matches.length - 1][1]) / 1000
}

function lastDurationSeconds(content) {
  const idx = content.lastIndexOf('playback_id:')
  const tail = idx === -1 ? content : content.slice(idx)
  const durMatches = [...tail.matchAll(/^ {4}duration: (\d+)/gm)].filter((m) => Number(m[1]) > 0)
  if (durMatches.length) return Number(durMatches[durMatches.length - 1][1]) / 1000
  const gaMatches = [...tail.matchAll(/"video_duration":"(\d{2}):(\d{2}):(\d{2})"/g)]
  const source = gaMatches.length ? gaMatches : [...content.matchAll(/"video_duration":"(\d{2}):(\d{2}):(\d{2})"/g)]
  if (!source.length) return null
  const [, hh, mm, ss] = source[source.length - 1]
  return Number(hh) * 3600 + Number(mm) * 60 + Number(ss)
}

// Decide (toques a escalar, segundos a sostener) según el tiempo restante.
// null significa "no tocar nada" (zona de aterrizaje final).
function planForRemaining(remainingSec) {
  const remainingMin = remainingSec / 60
  if (remainingSec <= STOP_TOUCHING_THRESHOLD) return null
  if (remainingMin > 20) return { level: 5, taps: 5, holdSec: 5 }
  if (remainingMin > 15) return { level: 3, taps: 3, holdSec: 3 }
  if (remainingMin > 10) return { level: 2, taps: 2, holdSec: 2 }
  // x1: un solo toque -- pero SÍ con un sostén mínimo antes del Select.
  // Hallazgo real (2026-09-11, corrida de validación E2E): con holdSec=0 el
  // Select llega ~150ms después del único toque de Fwd, demasiado rápido
  // para que el player registre el modo scrub -- el log mostraba
  // "RAFPlayerTask: state = playing" -> "paused" en cada ronda x1, es decir
  // el Select estaba actuando como Play/Pause en vez de confirmar un seek.
  // El "avance" que se veía en esa zona era en realidad reproducción en
  // tiempo real durante los ciclos de pausa/reanudación accidentales, no un
  // scrub real. Fix: sostener ~1s (igual que se hace en los demás niveles)
  // para que el Select sí confirme el seek.
  return { level: 1, taps: 1, holdSec: 1 }
}

async function main() {
  const logPath = process.argv[2]
  if (!logPath) {
    console.error('Uso: node scripts/smart-seek-agent.js <ruta-al-telnet.log>')
    process.exit(1)
  }

  let content = await readLog(logPath)
  const initialPid = lastPlaybackId(content)
  console.log(`playback_id inicial: ${initialPid ?? '<desconocido>'}`)

  let prevPos = null
  let stuckCount = 0
  let noDataTicks = 0
  // Hallazgo real (2026-09-11, corrida de validación E2E): algunos episodios
  // nunca loguean video_duration por GA4 (player_ready ausente) NI un
  // "duration:" > 0 en el bloque JSON de posición -- en ese caso el script
  // no tiene forma segura de saber cuándo frenar y antes se quedaba
  // reintentando en silencio hasta MAX_TICKS (80 x 2s = 160s) con un mensaje
  // final engañoso ("se agotaron los intentos sin llegar a la zona de
  // aterrizaje", que sugiere que sí hubo seeks). Fix: cortar antes con un
  // mensaje específico que deje claro que la causa es falta de duración, no
  // un fallo de aterrizaje.
  const MAX_NO_DATA_TICKS = 15 // ~30s sin poder leer duración -> avisar y salir

  for (let tick = 1; tick <= MAX_TICKS; tick++) {
    content = await readLog(logPath)
    const pidNow = lastPlaybackId(content)
    if (initialPid && pidNow && pidNow !== initialPid) {
      console.log(`⚠ El episodio cambió (playback_id ${initialPid} -> ${pidNow}). Probablemente se pasó del final. Frenando.`)
      process.exit(2)
    }

    const pos = lastPositionSeconds(content)
    const duration = lastDurationSeconds(content)
    if (pos == null || duration == null) {
      noDataTicks++
      console.log(`  [tick ${tick}] sin lectura de posición/duración todavía, espero... (${noDataTicks}/${MAX_NO_DATA_TICKS})`)
      if (noDataTicks >= MAX_NO_DATA_TICKS) {
        console.log('⚠ Nunca se pudo leer una duración válida (ni "duration:" > 0 en el bloque de posición ni "video_duration" de GA4) para este contenido -- no es seguro avanzar a ciegas. Frenando sin tocar nada más.')
        process.exit(3)
      }
      await new Promise((r) => setTimeout(r, 2000))
      continue
    }
    noDataTicks = 0
    const remaining = duration - pos
    console.log(`  [tick ${tick}] posición=${pos.toFixed(0)}s duración=${duration.toFixed(0)}s restante=${remaining.toFixed(0)}s`)

    if (remaining < 0) {
      console.log('⚠ Nos pasamos del final (restante negativo).')
      process.exit(1)
    }

    const plan = planForRemaining(remaining)
    if (!plan) {
      console.log(`Listo: restante=${remaining.toFixed(0)}s <= ${STOP_TOUCHING_THRESHOLD}s -- dejando correr en tiempo real hasta el final natural (Up Next aparece a ~5s).`)
      process.exit(0)
    }

    // Recuperación: posición sin cambios 3 lecturas seguidas -> probablemente
    // pausado -- Select de recuperación antes de seguir con el plan.
    if (prevPos !== null && pos === prevPos) {
      stuckCount++
      if (stuckCount >= 3) {
        console.log('  posición sin cambios 3 lecturas seguidas -- Select de recuperación (puede estar pausado)...')
        await ecpKeypress('Select')
        stuckCount = 0
        await new Promise((r) => setTimeout(r, 4000))
        continue
      }
    } else {
      stuckCount = 0
    }
    prevPos = pos

    console.log(`  decisión: nivel x${plan.level} (${plan.taps} toque(s) rápidos${plan.holdSec ? ` + sostener ~${plan.holdSec}s` : ''} + Select)`)
    await pressRepeat('Fwd', plan.taps)
    if (plan.holdSec) await new Promise((r) => setTimeout(r, plan.holdSec * 1000))
    await ecpKeypress('Select')

    await new Promise((r) => setTimeout(r, POLL_WAIT_MS))
  }

  console.log('⚠ Se agotaron los intentos sin llegar a la zona de aterrizaje.')
  process.exit(1)
}

main()
