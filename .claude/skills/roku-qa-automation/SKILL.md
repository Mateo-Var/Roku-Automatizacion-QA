---
name: roku-qa-automation
description: Retomar el proyecto de automatización de QA para la app Roku "TV Azteca En Vivo" (Mediastream) — arranca el Agente Player, valida el device, y trae todo el contexto acumulado sin tener que re-explicar nada. Usar cuando el usuario diga "retomemos el proyecto de Roku", "corré el agente player", "seguí con las pruebas del player de Azteca", o mencione el proyecto roku-qa-automation.
---

# Roku QA Automation — Azteca Player

Proyecto en `C:\Users\Mateo\roku-qa-automation\`. Automatiza QA del player
de la app Roku "TV Azteca En Vivo" (cliente Azteca de Mediastream) contra
un Roku físico real.

## Primer paso, siempre

Leé **completo** `C:\Users\Mateo\roku-qa-automation\PROJECT_MEMORY.md`
antes de hacer nada — es la fuente de verdad de todo lo ya investigado,
decidido y aprendido en sesiones anteriores (arquitectura de los 3 repos,
el bug conocido `SC-PLAYER-BUG-01`, la tabla de avance ya validada, y las
lecciones operativas). No repitas ese análisis, seguí desde ahí.

## Preguntá esto antes de tocar el device

**La IP del Roku de QA cambia entre sesiones** (se ha usado `192.168.1.34`,
un Roku Express, y `192.168.1.63`, un Streaming Stick 4K). Preguntale al
usuario cuál es la IP actual antes de conectarte — no asumas la última que
aparece en `PROJECT_MEMORY.md`, puede haber cambiado.

## Reglas críticas (ya aprendidas a las malas, no las repitas)

1. **Orden de conexión**: `Home` (keypress) → esperar ~1s → `launch/dev`
   (ECP) → esperar ~1.5s → RECIÉN AHÍ conectar el telnet (puerto 8085). Si
   el telnet se conecta antes del lanzamiento, el Roku deja de alimentar
   datos nuevos tras el dump inicial (queda "vivo" pero mudo).
2. **Relanzar un canal ya corriendo puede ser un no-op** (sin boot fresco)
   — por eso el paso `Home` primero, para forzar un cold start real.
3. **Validá siempre en dos capas antes de navegar**: ECP
   `GET http://<IP>:8060/query/active-app` debe decir `app id="dev"`, Y el
   log debe mostrar frescas `loadStatus:ready`, `HomePage:Init`,
   `showScreenhomePage`.
4. **Nunca combines `&` de shell con `run_in_background` del tool** — dejá
   el proceso de captura de telnet corriendo solo, sin encadenarlo.
5. **Navegación probada que funciona** para entrar a un show y reproducir
   (desde Home): `Down, Down, Right, Right, Select` (entra al show —
   confirmá `"screen_name":"Show"` en el log, nunca asumas que no aterrizó
   en un live), luego `Select` de nuevo ("Ver ahora" — confirmá
   `RAFPlayerTask: state = playing`).
6. **El avance (Fwd) no es lineal** — escala niveles de velocidad de scrub,
   no "X segundos por toque". Nunca lo calibres a ciegas. Tabla ya validada
   en 6+ corridas reales (ver `scripts/smart-seek-agent.js`,
   `ROKU_HOST=<IP> node scripts/smart-seek-agent.js <log>`):
   - restante > 20 min: x5 (5 toques rápidos + sostener ~5s + Select)
   - restante > 15 min: x3 (3 toques + sostener ~3s + Select)
   - restante > 10 min: x2 (2 toques + sostener ~2s + Select)
   - restante > ~2 min: x1 (1 toque + sostener ~1s + Select — el sostén es
     obligatorio, sin él el Select actúa como pausa en vez de confirmar)
   - restante <= ~2 min: cero toques, dejar correr en tiempo real hasta el
     final natural (los botones de "Next Episode"/Up Next aparecen a los
     ~5s del final, no antes).
7. **El botón "Next Episode"/Up Next vive en el Player SDK cerrado**, no en
   `ott-next-core-roku-tv` — no se puede instrumentar con logging propio.
8. **`SC-PLAYER-BUG-01`** (bug real, condición de carrera): `GET
   episode/.json` con ID vacío → 404 → `BRIGHTSCRIPT: ERROR: ParseJSON:
   Unknown identifier`. Solo aparece en selección MANUAL de episodio desde
   la lista (nunca en transiciones Up Next), y ni siquiera siempre ahí.

## Cómo trabajar: usá el Agente Player, no lo hagas vos turno a turno

Para cualquier tarea de validación/exploración contra el device real,
lanzá un subagente (Agent tool, `run_in_background: true`) llamado
"Agente Player" en vez de mandar keypresses vos mismo uno por uno. Dale
en el prompt: el contexto de arriba, la IP correcta del device, y la
tarea específica (validar un flujo, explorar QA general, probar una
corrida del script de avance, etc.). Ejemplos de tareas ya usadas con
éxito:
- Corrida completa E2E (navegar → reproducir → avanzar hasta cerca del
  final → observar transición de episodio).
- Exploración QA general (navegar shows variados, estresar controles,
  vigilar el log por anomalías, documentar por criticidad: crítico/mayor/
  menor).
- Probar/corregir `scripts/smart-seek-agent.js` contra el device real.

El agente debe: validar con evidencia real en cada paso (nunca asumir),
no esperar notificaciones externas (releer el log activamente él mismo),
manejar los estados raros del device por su cuenta (pausado, en el
launcher del sistema, en un live por error), y **actualizar él mismo
`PROJECT_MEMORY.md` al final** — no dejarlo para la sesión principal.

## Estructura del proyecto

```
roku-qa-automation/
├── PROJECT_MEMORY.md              ← leer siempre primero (resumen ejecutivo al inicio)
├── scenarios/
│   ├── shared/                    ← escenarios del Core, iguales para cualquier cliente
│   │   ├── README.md              ← convención de area/severity/status
│   │   ├── login-registro/        ← 8 escenarios, validados (ver status: DONE)
│   │   │   ├── scenarios.yaml
│   │   │   └── runbook.md         ← guión operativo (~18-20 min, política de capturas)
│   │   ├── navegacion/            ← 🆕 próxima batería, sin correr todavía
│   │   ├── player/                ← incluye SC-PLAYER-BUG-01 (bug confirmado)
│   │   └── boot-conectividad/
│   └── clients/
│       ├── azteca/profile.yaml    ← IP, flags conocidos, quirks -- NUNCA credenciales reales
│       └── _template/profile.yaml ← copiar para sumar un cliente nuevo
├── scripts/
│   ├── device-runner.js    ← runner Fase 1 (batería completa, YAML-driven)
│   ├── roku-type.js        ← tipeo scripteado del teclado en pantalla (usar siempre)
│   ├── seek-near-end.sh    ← versión bash de la tabla de avance (alternativa)
│   └── smart-seek-agent.js ← versión Node recomendada, ya validada
├── reports/
│   └── azteca/
│       ├── login-registro/        ← evidencia de cada corrida (README.md con convención)
│       ├── navegacion/            ← 🆕 vacío, listo
│       └── player-observation/
└── .env / .env.example     ← ROKU_HOST, ROKU_DEV_PASSWORD (nunca commitear .env real)
```
