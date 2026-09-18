# scenarios/shared/ — plantillas genéricas del Core (multi-cliente)

Reorganizado 2026-09-18 para soportar múltiples clientes sin romper nada
de lo ya validado. Ver `scenarios/clients/README.md` para el modelo
completo de cómo se organiza todo por cliente.

## Qué va acá

Solo escenarios verdaderamente genéricos, sin contenido/hallazgos
específicos de un cliente puntual (sin nombres de shows, sin cuentas de
prueba, sin bugs ya confirmados de un build particular) — pasos y
metodología reutilizables tal cual para cualquier cliente nuevo.

**Hoy esta carpeta está vacía de escenarios** porque, en la práctica, todo
lo que se corrió hasta ahora (login-registro, navegación, player,
analytics, boot-conectividad, performance) se validó contra un cliente
real (Azteca) o contra la app de referencia del Core ("Next"), y sus
`status`/evidencia quedaron mezclados con los pasos genéricos dentro de
cada escenario. Separar eso limpiamente (pasos genéricos acá + hallazgos
específicos en `clients/<cliente>/`) es trabajo pendiente, NO se hizo de
golpe en la reorganización del 2026-09-18 para minimizar el riesgo de
romper algo -- por ahora cada cliente tiene su propia copia completa
(steps + status) en `scenarios/clients/<cliente>/scenarios/`.

## Dónde está todo ahora

- `scenarios/clients/azteca/scenarios/` — las 6 baterías completas
  (login-registro, navegación, player, analytics, boot-conectividad,
  performance), 100% validadas contra TV Azteca En Vivo.
- `scenarios/clients/_reference/scenarios/` — los 9 escenarios de Up
  Next / Continue Watching validados contra la app de referencia del
  Core ("Next"), NO contra un cliente real -- separados de la batería de
  player de Azteca porque corrieron contra un build distinto.
- `scenarios/clients/_template/` — perfil vacío para arrancar un cliente
  nuevo.

## Convención de campos en cada `scenarios.yaml` (aplica en toda la carpeta clients/)

- `area`: etiqueta que usará el Test Router (Fase 3, no construida
  todavía) para decidir qué batería correr según el diff real:
  `player`, `core-network`, `core-ui`, `client-config`, `client-assets`.
- `severity`: `blocker` (bloquea release) / `major` / `minor`.
- `status` (cuando existe): resultado de la última corrida real contra el
  device, para NO reprocesar lo ya validado.
  - `DONE` -> ya se corrió y confirmó, no re-ejecutar salvo sospecha
    concreta de regresión.
  - `DONE-MANUAL-PENDING` -> la parte automatizable ya está lista, solo
    falta una confirmación humana externa (ej. email real) -- no es un
    test a re-correr.
  - `PARCIAL` -> el hallazgo actual es válido, pero se puede ampliar con
    MÁS casos nuevos (no repetir los ya cubiertos).
  - `SUPERSEDED por <ID>` -> este escenario quedó reemplazado por otro más
    específico.
  - `MERGED` -> se corrió integrado dentro de otro escenario.
  - Sin `status` -> todavía no se corrió nunca.
- Excepción a "no re-ejecutar": cuando el objetivo declarado del escenario
  ES reproducir un bug ya confirmado y se busca ADEMÁS una variante nueva
  -- eso no es reprocesar, es extender la evidencia a propósito.

## Cómo se arranca un cliente nuevo

1. Copiar `scenarios/clients/_template/profile.yaml` a
   `scenarios/clients/<nuevo-cliente>/profile.yaml`, completar IP del
   device, feature flags conocidos, etc.
2. Copiar la estructura de `scenarios/clients/azteca/scenarios/` como
   punto de partida (son los mismos componentes del Core, así que la
   mayoría de los pasos aplican tal cual) a
   `scenarios/clients/<nuevo-cliente>/scenarios/`.
3. Correr cada batería contra el device real de ese cliente, actualizando
   `status` con lo que se encuentre -- NO asumir que porque pasó en
   Azteca va a pasar igual en el cliente nuevo, cada uno puede tener
   personalización/feature flags distintos.
4. Si un caso da exactamente el mismo resultado en 2+ clientes sin
   ninguna diferencia relevante, es candidato a moverse acá a
   `scenarios/shared/` como plantilla genérica de verdad -- recién ahí
   vale la pena la separación fina de pasos-vs-hallazgos.
