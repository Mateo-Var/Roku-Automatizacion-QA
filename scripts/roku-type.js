#!/usr/bin/env node
// Helper de typing scripteado para el teclado en pantalla del Roku.
//
// Por qué existe: hasta hoy (2026-09-14) el Agente Player tipeaba carácter
// por carácter, un keypress ECP por turno de razonamiento del LLM -- eso es
// lo que hizo que una batería de 7 escenarios tardara ~30 minutos con 224
// acciones. La mecánica de "mandar N keypresses LIT_ con el delay correcto"
// no necesita criterio ni juicio -- es determinística, ya la aprendimos a
// las malas (ver PROJECT_MEMORY.md, notas de navegación del teclado). Este
// script la ejecuta de una sola invocación, para que el agente gaste su
// tiempo de razonamiento en LEER el resultado (log + captura), no en decidir
// tecla por tecla.
//
// Uso:
//   node scripts/roku-type.js "texto a tipear"
//   node scripts/roku-type.js "texto" --backspace 5      (antes de tipear, borra 5 caracteres)
//   node scripts/roku-type.js "texto" --cross-to-buttons  (al terminar, cruza de la grilla QWERTY a la columna de botones: right x10 + right + down, secuencia validada en PROJECT_MEMORY.md)
//   node scripts/roku-type.js "texto" --delay 150         (ms entre teclas, default 150 -- bajarlo puede perder teclas por debounce, ver lecciones ya documentadas)
//
// Requiere ROKU_HOST en .env. Imprime un JSON de una línea al final con lo
// que mandó, para que el agente pueda loguearlo sin ambigüedad:
//   {"sent":"texto","chars":5,"backspacesSent":0,"crossedToButtons":false}
//
// IMPORTANTE -- lo que este script NO hace (a propósito):
// no verifica por sí mismo que el campo haya quedado bien escrito. Esa
// verificación (log + captura con MOSTRAR si es password) la sigue haciendo
// el agente DESPUÉS de llamar a este script, una sola vez por campo en vez
// de una vez por tecla -- así se mantiene el doble chequeo (log + visual)
// que atrapa errores de navegación, pero sin pagar el costo de hacerlo tecla
// por tecla.
//
// VERIFICACIÓN POR LOG (validado contra el device real 2026-09-14): cada
// caracter tipeado por LIT_ queda en el telnet log como
//   onKeyEvent : key = Lit_<char> press = false
// (OJO: a diferencia de las teclas de navegación, el literal NO loguea un
// "press = true" separado, solo "press = false"). El agente puede extraer
// con una sola regex la secuencia de caracteres realmente recibida y
// compararla contra `sent` del JSON que este script imprime, ANTES de
// gastar una captura -- ejemplo de regex:
//   /onKeyEvent : key = Lit_(.) press = false/g
// IMPORTANTE: el telnet tiene que estar conectado ANTES de invocar este
// script (el log solo transmite eventos desde el momento de la conexión en
// adelante, no historial -- confirmado 2026-09-14, ver PROJECT_MEMORY.md).

import 'dotenv/config'

const ROKU_HOST = process.env.ROKU_HOST
const ECP_PORT = process.env.ROKU_ECP_PORT || '8060'

if (!ROKU_HOST) {
  console.error('Falta ROKU_HOST -- copiá .env.example a .env y completalo.')
  process.exit(1)
}

async function ecpKeypress(key) {
  const res = await fetch(`http://${ROKU_HOST}:${ECP_PORT}/keypress/${key}`, { method: 'POST' })
  if (!res.ok) throw new Error(`ECP keypress ${key} -> HTTP ${res.status}`)
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms))
}

// El @ (y otros símbolos reservados de URL) SIEMPRE tienen que ir
// URL-encoded explícito -- confirmado en sesión 2026-09-14 que LIT_@ crudo
// a veces se pierde silenciosamente (produjo "qa.testerexample.com"
// sin arroba). encodeURIComponent ya lo resuelve para cualquier caracter,
// no solo @.
function literalKeyFor(char) {
  return `LIT_${encodeURIComponent(char)}`
}

async function typeText(text, delayMs) {
  for (const char of text) {
    await ecpKeypress(literalKeyFor(char))
    await sleep(delayMs)
  }
}

async function backspaceN(n, delayMs) {
  for (let i = 0; i < n; i++) {
    await ecpKeypress('Backspace')
    await sleep(delayMs)
  }
}

// Secuencia validada en PROJECT_MEMORY.md (sesión 2026-09-14) para cruzar
// de forma confiable desde la grilla QWERTY (donde queda el foco después de
// tipear) hasta la columna de botones de la derecha: parar en la columna
// derecha de la grilla (10 "right"), un "right" más para cruzar, recién
// ahí "down". Enviar los "right" de a uno con delay, no en ráfaga -- ya se
// confirmó que keypresses idénticos consecutivos sin espaciar se pierden
// por debounce del lado del Roku.
async function crossGridToButtons(delayMs) {
  for (let i = 0; i < 10; i++) {
    await ecpKeypress('Right')
    await sleep(delayMs)
  }
  await ecpKeypress('Right')
  await sleep(delayMs)
  await ecpKeypress('Down')
  await sleep(delayMs)
}

async function main() {
  const args = process.argv.slice(2)
  const text = args[0]
  if (!text || text.startsWith('--')) {
    console.error('Uso: node scripts/roku-type.js "texto" [--backspace N] [--cross-to-buttons] [--delay ms]')
    process.exit(1)
  }
  const backspaceIdx = args.indexOf('--backspace')
  const backspaceN_ = backspaceIdx !== -1 ? Number(args[backspaceIdx + 1]) : 0
  const crossToButtons = args.includes('--cross-to-buttons')
  const delayIdx = args.indexOf('--delay')
  const delayMs = delayIdx !== -1 ? Number(args[delayIdx + 1]) : 150

  if (backspaceN_ > 0) await backspaceN(backspaceN_, delayMs)
  await typeText(text, delayMs)
  if (crossToButtons) await crossGridToButtons(delayMs)

  console.log(JSON.stringify({
    sent: text,
    chars: text.length,
    backspacesSent: backspaceN_,
    crossedToButtons: crossToButtons,
  }))
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
