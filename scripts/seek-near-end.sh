#!/usr/bin/env bash
# Avanza un episodio en reproducción hasta dejarlo a ~15-30s del final,
# sin pasarse -- sin importar cuánto dure el episodio.
#
# Por qué existe: el avance (Fwd) de este player NO es lineal -- parece
# acelerar mientras más toques seguidos le des (40 toques movieron ~1831s
# una vez, pero otros 120 toques se pasaron de largo un episodio de 4085s
# completo). Tocar a ciegas un número fijo de veces sobrepasa el final o se
# queda corto según el momento. Este script en cambio MIDE la posición real
# leyéndola del log (Library/logs vía telnet) después de cada tanda, y
# ajusta el tamaño de la tanda según cuánto falte -- tandas grandes al
# principio, chiquitas cerca del final, nunca a ciegas.
#
# Uso: ./scripts/seek-near-end.sh <ruta-al-telnet.log> [duracion_segundos]
#   Si no se pasa la duración, la lee del último "video_duration" (HH:MM:SS)
#   visto en el log.
set -euo pipefail

HOST="${ROKU_HOST:-192.168.1.34}"
LOG="$1"
SLOW_PHASE_THRESHOLD=180  # a partir de acá (3 min restantes) se deja el avance rápido y se va de a un toque
STOP_THRESHOLD=60         # si falta menos de esto, mejor parar ahí que arriesgar otro salto impredecible

press_fwd_burst() {
  local n="$1"
  for _ in $(seq 1 "$n"); do
    curl -s -m 3 -X POST "http://$HOST:8060/keypress/Fwd" > /dev/null || true
  done
  curl -s -m 3 -X POST "http://$HOST:8060/keypress/Select" > /dev/null || true
}

# Para el ajuste fino cerca del final (zona 3): Fwd+Select entra en modo
# scrub acelerado y NI SIQUIERA un solo toque es predecible ahí (se vio
# saltar de 218s a 1s restante con burst=1 -- confirmado 2026-09-11).
# Right hace un salto directo (~10s) SIN entrar a modo scrub, no necesita
# Select para confirmar. Con esto el resto por cubrir en zona 3 (a lo sumo
# ~150s) se hace en pocos toques y de forma mucho más predecible.
press_right_once() {
  curl -s -m 3 -X POST "http://$HOST:8060/keypress/Right" > /dev/null || true
}

hhmmss_to_seconds() {
  local hh mm ss
  IFS=: read -r hh mm ss <<< "$1"
  echo $((10#$hh * 3600 + 10#$mm * 60 + 10#$ss))
}

current_playback_id() {
  grep -oE '"?playback_id"?: ?"[^"]+"' "$LOG" | tail -1 | grep -oE '"[A-Za-z0-9]+"$' | tr -d '"'
}

current_position_seconds() {
  # Busca la posición reportada DESPUÉS del último playback_id conocido, para
  # no confundirse con la cola de un episodio anterior si ya hubo transición.
  local last_pid_line
  last_pid_line=$(grep -n "playback_id:" "$LOG" | tail -1 | cut -d: -f1 || echo 1)
  local pos_ms
  pos_ms=$(tail -n +"$last_pid_line" "$LOG" | grep "^    position:" | tail -1 | grep -oE '[0-9]+' || echo "")
  if [ -z "$pos_ms" ]; then echo ""; return; fi
  echo $((pos_ms / 1000))
}

current_duration_seconds() {
  # Preferido: el campo "duration:" (ms) del mismo bloque JSON que
  # "position:" -- sincronizado de verdad con la sesión de playback activa.
  # Viene en 0 en los primeros frames hasta que el player resuelve el
  # stream real, así que se descarta el 0 y se toma el último valor real.
  local last_pid_line
  last_pid_line=$(grep -n "playback_id:" "$LOG" | tail -1 | cut -d: -f1 || echo 1)
  local dur_ms
  dur_ms=$(tail -n +"$last_pid_line" "$LOG" | grep "^    duration:" | grep -v ': 0$' | tail -1 | grep -oE '[0-9]+' || echo "")
  if [ -n "$dur_ms" ]; then
    echo $((dur_ms / 1000))
    return
  fi
  # Fallback: algunos contenidos nunca resuelven "duration:" (queda en 0
  # toda la sesión, visto 2026-09-11) -- usar el "video_duration" (HH:MM:SS)
  # del evento GA4 player_ready, buscado DESDE el arranque de esta sesión
  # (primera ocurrencia después del último playback_id nuevo, no la última
  # del archivo completo, para no agarrar la de un episodio ya terminado).
  local hhmmss
  hhmmss=$(tail -n +"$last_pid_line" "$LOG" | grep -oE '"video_duration":"[0-9]{2}:[0-9]{2}:[0-9]{2}"' | head -1 | grep -oE '[0-9]{2}:[0-9]{2}:[0-9]{2}')
  if [ -z "$hhmmss" ]; then
    # También puede haber aparecido ANTES de la línea de playback_id (el
    # evento player_ready suele dispararse un poco antes); si no se
    # encontró después, buscar la última ocurrencia en todo el archivo
    # como último recurso.
    hhmmss=$(grep -oE '"video_duration":"[0-9]{2}:[0-9]{2}:[0-9]{2}"' "$LOG" | tail -1 | grep -oE '[0-9]{2}:[0-9]{2}:[0-9]{2}')
  fi
  if [ -z "$hhmmss" ]; then echo ""; return; fi
  hhmmss_to_seconds "$hhmmss"
}

# Duración y playback_id se releen EN CADA VUELTA -- no una sola vez al
# principio. El bug real que esto corrige: si el episodio termina y pasa al
# siguiente a mitad del script (autoplay), la duración vieja queda
# desactualizada y "restante" se calcula mal contra un episodio distinto,
# haciendo que el script siga avanzando a ciegas varias tandas de más antes
# de notarlo. Ahora, apenas cambia el playback_id, se frena y se reporta en
# vez de seguir.
INITIAL_PID=$(current_playback_id)
echo "playback_id inicial: ${INITIAL_PID:-<desconocido>}"

PREV_POS=""
STUCK_COUNT=0

MAX_ITERATIONS=40
for i in $(seq 1 "$MAX_ITERATIONS"); do
  PID_NOW=$(current_playback_id)
  if [ -n "$INITIAL_PID" ] && [ -n "$PID_NOW" ] && [ "$PID_NOW" != "$INITIAL_PID" ]; then
    echo "⚠ El episodio cambió durante el avance (playback_id ${INITIAL_PID} -> ${PID_NOW})."
    echo "  Probablemente se pasó del final del episodio original. Frenando para no seguir a ciegas."
    exit 2
  fi

  DURATION_SECONDS=$(current_duration_seconds)
  POS=$(current_position_seconds)
  if [ -z "$POS" ] || [ -z "$DURATION_SECONDS" ]; then
    echo "  [iter $i] sin lectura de posición/duración todavía, espero un poco..."
    sleep 2
    continue
  fi
  REMAINING=$((DURATION_SECONDS - POS))
  echo "  [iter $i] posición=${POS}s, duración=${DURATION_SECONDS}s, restante=${REMAINING}s"

  # Recuperación: el log de posición se refresca cada ~30-60s reales, así
  # que ver la MISMA posición una sola vez de una vuelta a la siguiente es
  # normal (no alcanzó a llegar el próximo evento) -- no dispara nada. Pero
  # si se repite 3 veces seguidas (~90s+ reales sin ningún cambio), es
  # señal real de que algo se frenó (visto 2026-09-11: una tanda de Fwd
  # interrumpida a mitad dejó el player pausado). Ahí sí, en vez de seguir
  # mandando Fwd a ciegas sobre un player que no avanza, se manda un
  # Select/OK de recuperación (confirma un scrub pendiente, o despausa) y
  # se vuelve a leer antes de decidir nada más.
  if [ "$PREV_POS" = "$POS" ]; then
    STUCK_COUNT=$((STUCK_COUNT + 1))
    if [ "$STUCK_COUNT" -ge 3 ]; then
      echo "  [iter $i] posición sin cambios 3 vueltas seguidas -- mandando Select/OK de recuperación..."
      curl -s -m 3 -X POST "http://$HOST:8060/keypress/Select" > /dev/null || true
      STUCK_COUNT=0
      sleep 4
      continue
    fi
  else
    STUCK_COUNT=0
  fi
  PREV_POS="$POS"

  if [ "$REMAINING" -lt 0 ]; then
    echo "⚠ Nos pasamos del final (restante negativo: ${REMAINING}s)."
    exit 1
  fi
  if [ "$REMAINING" -le "$STOP_THRESHOLD" ]; then
    echo "Listo: quedó a ${REMAINING}s del final (objetivo: como mucho ${STOP_THRESHOLD}s)."
    exit 0
  fi

  # Tabla directa: cuántas pulsaciones de Fwd según el tiempo restante --
  # no una fórmula, una tabla fija (x1/x2/x3), calibrada conservador con lo
  # que ya se vio en pruebas reales: 2 toques llegaron a saltar de largo
  # 426s restantes una vez, así que por debajo de 10 min NUNCA se manda
  # más de x1 (1 toque). Por debajo de 3 min se deja el scrub del todo y
  # se pasa a Right (salto directo, sin acelerar más).
  if [ "$REMAINING" -gt 1200 ]; then
    BURST=3
    echo "  [iter $i] restante > 20min -- avance x3 (${BURST} Fwd) + Select..."
  elif [ "$REMAINING" -gt 600 ]; then
    BURST=2
    echo "  [iter $i] restante > 10min -- avance x2 (${BURST} Fwd) + Select..."
  elif [ "$REMAINING" -gt "$SLOW_PHASE_THRESHOLD" ]; then
    BURST=1
    echo "  [iter $i] restante > 3min -- avance x1 (${BURST} Fwd) + Select..."
  else
    echo "  [iter $i] restante <= 3min -- ajuste fino con Right (sin scrub)..."
    press_right_once
    sleep 6
    continue
  fi
  press_fwd_burst "$BURST"
  # El evento de posición en el log solo se refresca cada ~30-60s reales
  # (periodicPlayingEventExpired) -- esperar poco aquí solo hace que varias
  # vueltas vean la misma lectura vieja y parezca que no avanzó nada.
  sleep 6
done

echo "⚠ Se agotaron los intentos sin llegar al rango objetivo." >&2
exit 1
