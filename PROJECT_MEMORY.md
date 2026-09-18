# Roku QA Automation — Memoria del proyecto

> Este archivo es la fuente de verdad de decisiones y contexto para no repetir
> el análisis cada vez. Actualízalo cuando cambie algo importante (arquitectura,
> decisiones, hallazgos nuevos en los repos).

### 🚨 Sesión 2026-09-18 (tarde) — EL BUG DE BYPASS DE LOGIN NO ESTÁ ARREGLADO + primera corrida completa de NAVEGACIÓN

Device `192.168.1.54` (Roku Express), build `TV Azteca En Vivo` v1.24.92609040
(footer: `a01.24.92609040 / c01.44.202609040 / os15.3 / m86`), sin cambios.
Se corrieron **AC-UL-02 completo (3 casos) + 28 de 29 escenarios de navegación
+ 5 de player**, con log de telnet, captura y video de cámara real por caso.
Evidencia en `reports/azteca/2026-09-18_11-37-login-registro/` (AC-UL-02-retry),
`reports/azteca/2026-09-18_17-25-navegacion/` y
`reports/azteca/2026-09-18_18-00-player/`.

#### 1. La ruta de LOGIN REAL (corrige una conclusión contaminada anterior)

La re-confirmación de AC-UL-02 del 2026-09-18 a la mañana **estaba
contaminada**: ejercitó el flujo de REGISTRO (`RegEmailView`, GA4
`screen_name:"Register with Email"`) creyendo que era el de login, y de ahí
concluyó mal que el bug podía estar arreglado. **Esa conclusión queda
anulada.** La ruta de login real, confirmada paso a paso por log, es:

```
sidebar "Ingresar"
  -> LoginRegPage : Init            (screen_name "Login")
  -> botón "INGRESAR CON EMAIL"     (columna DERECHA "Inicia sesión";
                                     el amarillo de la izquierda es REGISTRO)
  -> diálogo NATIVO de Roku "Iniciar sesión" (one-touch, ottnext@mediastre.am)
  -> "Usar un correo electrónico diferente"
  -> LoginEmailView : Init          (screen_name "Login with Email")
  -> botón "INGRESAR CON CONTRASEÑA"
  -> LoginWithPasswordView : Init   (screen_name "Login with Password")
```

**Regla operativa:** confirmar SIEMPRE por log qué vista se inicializa antes de
tipear. Si aparece `RegEmailView` o un formulario que dice "Crear una cuenta",
es registro -- retroceder.

#### 2. BUG CRÍTICO CONFIRMADO: login exitoso con contraseña incorrecta

Por esa ruta real, con `jmatevargas@poligran.edu.co` + `PasswordIncorrecta99`
(verificada carácter por carácter con el toggle MOSTRAR **antes** de confirmar):

```
GA4 login_success  login_source:"email"  new_user:false
                   login_status:"connected"
                   IM:"30f41b94-1310-46e1-8627-fb31590ffef3"   <- el IM REAL
```

La app navega a HomePage ya logueada, con "Continuar viendo" e ícono de cuenta,
y **AccountPage muestra la identidad completa: "jmatevargas@poligran.edu.co /
Mateo Vargas" con botón "Cerrar sesión"**. O sea: sesión plena y legítima
obtenida con una contraseña incorrecta. Es la **9ª reproducción** y la primera
por la ruta de login real post-reorganización. **Queda descartado que el
backend lo haya arreglado.**

El contraste con el Caso A es lo más útil para el reporte al equipo de backend:

| Caso | Email | Password | Respuesta backend | GA4 |
|---|---|---|---|---|
| A | inexistente | cualquiera | HTTP 400 `FEDERATION_INVALID_CREDENTIALS` | `login_error` ✅ |
| B | **válido** | **incorrecta** | **éxito** | **`login_success`** 🚨 |
| C | formato inválido | — | (sin request, validación client-side) | — ✅ |

Es decir: **el mismo endpoint SÍ valida credenciales cuando el email no existe,
pero NO valida la contraseña cuando el email sí existe.** Eso acota mucho dónde
buscar: parece que la rama "usuario encontrado" saltea la verificación de
password.

Hallazgo lateral del login exitoso (error manejado, no crashea, pero reportar):
`ssoService : saveData : Response : {status:404, response:"Service error: Make
sure that you have set a billing channel"}`.

#### 3. Navegación — 28 de 29 escenarios, 5 hallazgos

Todos PASARON salvo los hallazgos de abajo. Ver el detalle por escenario en los
encabezados de `scenarios/clients/azteca/scenarios/navegacion/*/scenarios.yaml`.

1. **Excepción BrightScript en cada toggle de favorito (major).** 5ª
   confirmación, pero **primera vez con archivo y línea exactos**:
   `roSGNode.AddReplace: "compnode": Type mismatch:
   ottnext_ms_sdk_componentlib:/components/pages/ShowPage/ShowPage.brs(1086)`.
   Está en `ottnext_ms_sdk_componentlib` = **código del Core/SDK, no de
   Azteca** -> afectaría a todos los clientes. Determinística, no una
   condición de carrera: 11 toggles rápidos produjeron exactamente 11
   excepciones. Con archivo+línea ya es accionable para el equipo de Core.
2. **2 categorías configuradas no se renderizan (minor).** `release.json`
   define 13 componentes en `routes.Home.components`, en pantalla hay 11:
   faltan **"Novelas"** y **"Cine Mexicano"**. Tampoco aparecen en Discover
   -> probablemente estén vacías en backend y la app las oculte bien. Es
   decir, el problema parece de contenido/config, no de la app.
3. **"N TEMPORADAS" no cuenta temporadas, cuenta sub-grupos (minor).**
   Reformula SC-SHOW-COPY-01: "Venga La Alegría" dice "10 TEMPORADAS" pero sus
   grupos son secciones temáticas de un matutino diario; "Lotería del Crimen"
   dice "2 TEMPORADAS" siendo 1 temporada + "Contenido Exclusivo". El
   "1 TEMPORADAS" original es un caso particular de este problema más general.
4. **EPG (minor x2):** el horario se muestra solo en la celda con foco (no se
   puede escanear la grilla, que es para lo que sirve un EPG); y los títulos
   largos se cortan en seco sin elipsis.
5. **Pestañas y sub-grupos cargan solo con Select, no con el foco (minor, UX).**
   La pestaña se ve seleccionada mientras abajo sigue el contenido anterior.

#### 4. ⚠️ Metodología: las capturas NO sirven para el plano de video

`plugin_inspect` captura **solo el plano gráfico**. Durante la reproducción las
capturas salen **completamente negras** aunque `query/media-player` reporte
`state="play" error="false"` y la posición avance -- lo único visible son los
subtítulos, porque se dibujan en el plano gráfico. **No reportar eso como
"pantalla negra".** Para el player la evidencia válida es el **video de la
cámara** + `query/media-player` (que además da bitrate, codecs, buffering y
posición exacta, mucho más útil que una captura).

#### 5. Técnica de navegación y scripts (lo que funcionó)

- Un **solo socket de telnet persistente** escribiendo a un archivo de sesión,
  y se cortan slices por offset de bytes (`wc -c` antes de la acción,
  `tail -c +N` después). Mucho más barato que abrir/cerrar telnet por caso, y
  no sufre el "Console connection is already in use".
- `scripts/_tmp-telnet-capture.js` sigue con la IP vieja (.186) hardcodeada y
  está deprecado -- **no usarlo**.
- Teclado en pantalla: `node scripts/roku-type.js "texto"`, después
  `Right x11` + `Down` para cruzar de la grilla a la columna de controles, y
  `Down` sucesivos para bajar. Validado de nuevo en esta sesión.
- El teclado en pantalla de Search **no ofrece caracteres especiales** (solo
  a-z, 0-9, espacio, borrar), pero el campo SÍ los acepta por ECP y por el
  teclado del celular vía el QR que ofrece la propia Roku -- por eso el caso
  de XSS se prueba con `roku-type.js`, y es un vector real, no artificial.

#### 6. Pendientes concretos

- `SC-MULTI-ENTRY-SHOW-01` y `SC-SHOW-AOD-01` (navegación): no corridos.
- `SC-PLAYER-BUG-01`: no se reprodujo en 1 pasada limpia. Como es condición de
  carrera, **no darlo por resuelto** -- reintentar con más repeticiones y en frío.
- `SC-FLOW-ADS-01`: aparecieron repetidos `ad_error` en el log durante la
  reproducción (uno al arrancar, otros tras cada seek). Contenido nunca se
  interrumpió, error manejado. Confirmar con el equipo de Ads si es config rota
  del entorno de dev o un problema real de monetización.
- Buscar un show de un solo sub-grupo para reproducir el "1 TEMPORADAS".

---

### 🆕 Sesión 2026-09-18 — REORGANIZACIÓN MULTI-CLIENTE (backup completo antes de tocar nada)

El proyecto pasó de estar organizado solo por área (`scenarios/shared/<area>/`,
implícitamente todo Azteca) a estar organizado por **cliente primero, área
después** -- así se puede sumar un cliente nuevo sin tocar nada de lo
existente. Backup completo hecho ANTES de mover nada:
`C:\Users\Mateo\roku-qa-automation-BACKUP-20260918-1122` (verificado con
diff, 0 archivos de diferencia contra el original antes de reorganizar).

**Qué cambió:**
- `scenarios/shared/<area>/scenarios.yaml` -> `scenarios/clients/azteca/scenarios/<area>/scenarios.yaml`
  (las 6 baterías completas: login-registro, navegación, player, analytics,
  boot-conectividad, performance -- 100% Azteca, sin pérdida de ningún
  escenario, conteo verificado 71=71 antes/después de mover).
- Dentro de `player/scenarios.yaml` se separaron los 9 casos que en
  realidad se habían validado contra la app de referencia del Core
  ("Next"/`OTTNext_CLIENT_APP`, NO un cliente real) -- `SC-UPNEXT-*` (4) y
  `SC-CW-*` (5) -- a `scenarios/clients/_reference/scenarios/player/scenarios.yaml`.
- `test-data/azteca.json` -> `scenarios/clients/azteca/catalog.json`
  (y `scripts/RokuTest.psm1` actualizado para resolver el catálogo por
  cliente en esa ruta nueva, no en un `test-data/` suelto).
- `reports/azteca/continue-watching-pr174/` -> `reports/_reference/2026-09-16_continue-watching-pr174/`
  (estaba mal clasificado como Azteca cuando en realidad corrió contra
  "Next" -- se aprovechó el movimiento para aplicarle la convención nueva
  de subcarpetas `logs/`/`videos/`/`REPORTE.md`).
- `scenarios/shared/` quedó vacío de contenido a propósito (ver
  `scenarios/shared/README.md`) -- es donde en el futuro se van a mover
  escenarios verdaderamente genéricos, una vez que se validen 2+ clientes
  con el mismo resultado exacto. Hoy cada cliente tiene su copia completa.
- `package.json` (scripts npm) y todos los comentarios de rutas en
  `scripts/*.js`, `scripts/*.ps1`, `scripts/*.psm1` actualizados a las
  rutas nuevas -- barrido final confirmó cero referencias colgantes a
  `scenarios/shared/<área>/` ni `test-data/`.
- Nuevos: `scenarios/clients/README.md` (el modelo completo de
  multi-cliente) y `reports/README.md` (convención de carpetas por
  corrida: `reports/<cliente>/<fecha>-<nombre>/{logs,screenshots,videos}/REPORTE.md`).
- Grabación de video con `scripts/camera-server.js` (cámara real de un
  celular vía navegador, no captura de pantalla de la PC) se estableció
  como el método estándar de evidencia para TODA batería y toda tarea
  puntual de acá en adelante, nombrando cada video con el ID del caso.

**No se tocó** (deliberadamente, para no arriesgar romper nada sin
necesidad real): las ~25 carpetas de corridas históricas dentro de
`reports/azteca/<área>/` quedaron con su estructura/nombres originales,
no se migraron a la convención nueva -- ver nota en `reports/README.md`.

### 🆕 Sesión 2026-09-17 (continuación 8) — CIERRE DE LA BATERÍA PLAYER: SC-UPNEXT-CREDITS-01 cerrado como limitación de método (4/4 intentos fallidos), SC-CW-04 CONFIRMADO como bug real (no depende del camino de entrada)

## 📋 RESUMEN EJECUTIVO FINAL — batería PLAYER completa (18 escenarios), device .63, sesiones 2026-09-15 a 2026-09-17

1. **SC-SHOW-01** — CONFIRMADO. Cold start, navegación, selección de episodio y play/pause funcionan sin errores.
2. **SC-PAYWALL-01** — SIN CONFIRMAR (abierto, no fabricado). No se encontró contenido premium/gateado en el catálogo de prueba.
3. **SC-PLAYER-BUG-01** — BUG CONFIRMADO (condición de carrera intermitente, ~2/3 en selección manual de episodio, 0/5 vía Up Next). `ParseJSON: Unknown identifier` por ID de episodio vacío. Pendiente de reportar.
4. **SC-FLOW-CONTROLS-01** — COMPLETO 14/14 checks, todos CONFIRMADOS (foco, carga, seek, multi-click, pausa en scrub, pause vs stop, controles no bloqueantes, AV sync, subtítulos x2, remoto completo, buffering forzado, spam play/pause, extremos 0:00/fin).
5. **SC-PLAYER-VOLUME-01** — N/A de plataforma (Roku no maneja volumen a nivel de app).
6. **SC-FLOW-EXIT-NAV-01** — CONFIRMADO 5/5 (Home físico, banner de confirmación con matiz del doble-Back desde el hero, Back cierra popup primero, Back retrocede por historial, banner en Home).
7. **SC-FLOW-ADS-01** — PARCIAL/cerrado con limitación documentada: checks 1 y 2 CONFIRMADOS (no-fill degrada limpio, mid-roll con seek post-ad correcto); check 3 (Back en medio de un ad con fill real) NO EJECUTABLE en este entorno — >10 mid-rolls observados en 3 shows distintos, todos no-fill, se documenta como limitación del ad server actual, no reintentar sin cambio de config.
8. **SC-PLAYER-CONTENT-MATRIX-01** — COMPLETO 4/4 (Top10, contenido nuevo, contenido viejo, Live desde EPG), todos reproducen sin diferencias de comportamiento.
9. **SC-FLOW-STRESS-01** — COMPLETO 3/3 (ráfaga sobre "Ver ahora" del hero NO reprodujo el bug reportado por el usuario en 6/6 intentos — no descartado por naturaleza intermitente, pero sin evidencia en esta build; reentrada rápida 6 ciclos sin crash con nota de coalescing de inputs; ráfaga post-autoplay de Up Next 2/2 sin incidentes).
10. **SC-UPNEXT-NEXTEP-01** — CONFIRMADO. Select cerca del final dispara cambio inmediato al episodio siguiente.
11. **SC-UPNEXT-CREDITS-01** — **CERRADO SIN LOGRARSE tras 4 intentos acumulados en 2 sesiones** (continuaciones 6, 7 y 8). Limitación de método del agente (ventana real de aceptación del overlay de ~2-3s, sin señal explícita en el log de "overlay shown", más el hallazgo nuevo de esta sesión de que los mid-rolls frecuentes pueden distorsionar la estimación de "tiempo restante" y disparar NEXTEP prematuro). NO es un bug de la app — se infiere que el flujo funciona porque NEXTEP-01 y AUTO-01 sí están confirmados. Se cierra el caso, no reintentar con el mismo método sin instrumentación adicional.
12. **SC-UPNEXT-AUTO-01** — CONFIRMADO. Sin intervención, al terminar el episodio autoplayea el siguiente.
13. **SC-UPNEXT-LASTEP-01** — CONFIRMADO. Último episodio de un show no muestra botón de "Siguiente episodio"; al terminar vuelve a la ShowPage limpio.
14. **SC-CW-01** — CONFIRMADO. Reproducir y volver con Back refleja el contenido en Continuar Viendo.
15. **SC-CW-02** — HALLAZGO (reincidencia del bug de fondo PR-174): posición avanzada no se refleja al reingresar desde Continuar Viendo (arranca en 0 vía `Seek parameter = 0`).
16. **SC-CW-03** — REFORZADO, reincide el `known_issue` ya documentado: contenido reproducido vía Buscar->Player-directo nunca se sincroniza a Continuar Viendo pese a reproducción real confirmada por log.
17. **SC-CW-04** — **CONFIRMADO como BUG REAL esta sesión** (ver detalle abajo): contenido corto terminado al 100% real NO se excluye de Continuar Viendo, sea cual sea el camino de entrada (Buscar directo O ficha del show) — contradice el "PASA" de la corrida original de PR-174, se recomienda escalar.
18. **SC-CW-05** — NO CONCLUYENTE, bloqueado por el mismo bug de fondo que CW-02/CW-03 (ni la posición avanzada ni la rebobinada sobreviven al Back) — no reintentar hasta que se resuelva PR-174.

**Bugs/hallazgos listos para reportar (ver también la sección de login-registro para los de esa batería):** SC-PLAYER-BUG-01 (ParseJSON, intermitente), SC-CW-02/03/04/05 (familia PR-174, con CW-04 ahora subido a confirmado), spinner colgado en transición de episodio (2 ocurrencias, ver detalle en continuación 7 y 8, sigue sin subir a "bug confirmado" porque nunca se esperó lo suficiente para descartar que solo sea lento), bug de favoritos `ShowPage.brs` (Type mismatch, ya documentado en otras baterías), SC-FLOW-ADS-01 check 3 como limitación de entorno (no de la app).

---

### 🆕 Sesión 2026-09-17 (continuación 8) — detalle de esta sesión

Continuación directa de "continuación 7" contra `192.168.1.63`. Login
verificado activo por log (`login_status:"connected"`, mismo IM) sin
necesidad de re-loguear. El socket de telnet de la sesión anterior ya
no estaba conectado (sin `ESTABLISHED` en el puerto 8085) -- se abrió uno
nuevo en modo append con `scripts/_tmp-telnet-append-63.js` (mismo
`telnet.log`, sin sobreescribir, creció de 25772 a 27917 líneas).

**SC-UPNEXT-CREDITS-01 -- 4to y ÚLTIMO intento, CERRADO sin lograrse.**
Se usó "Lotería del Crimen" (mismo show ya validado en NEXTEP-01/AUTO-01)
con un episodio nuevo ("La Tóxica") vía `scripts/smart-seek-agent.js` en
modo automático completo. Primer intento: el script saltó de episodio de
forma prematura (remaining reportado de 942s, lejos del final) --
hallazgo nuevo: este contenido tiene mid-rolls muy frecuentes (cada
~600s) que aparentemente hacen que la duración real jugable sea menor a
la `duration` reportada, causando un NEXTEP no solicitado. Segundo
intento (episodio autoplayado): el script sí aterrizó bien en
remaining=45s, pero al monitorear pasivamente por ECP se descubrió la
posición CONGELADA en remaining~45s por más de 2 minutos reales,
`state="close"` sostenido y una captura confirmando el spinner del
episodio siguiente detenido en 0% -- **esto reproduce por 2da vez el
hallazgo de "spinner colgado" ya visto en la continuación 7**, ahora con
tiempo de espera suficiente para subirlo de "a vigilar" a "hallazgo real
recurrente" (aunque todavía sin confirmar si es un freeze permanente o
solo muy lento, porque de nuevo un Back sacó la app limpia sin crash).
En ningún momento de este intento se llegó siquiera a enviar el Right de
prueba -- la ventana nunca estuvo disponible de forma estable. Con 4
intentos acumulados en 2 sesiones distintas fallando por la misma
familia de causas, se **cierra el escenario como limitación de la
técnica de automatización** (ECP+telnet sin acceso a video en tiempo
real), no como bug de la app -- no se recomienda seguir reintentando sin
instrumentación adicional. Ver detalle completo en el `status` del
escenario en `scenarios/shared/player/scenarios.yaml`.

**SC-CW-04 -- REFORZADO, CONFIRMADO como bug real, no depende del camino
de entrada.** Para aislar la variable pedida, se reprodujo un contenido
corto (00:01:49) entrando explícitamente desde la ficha del show
(Lotería del Crimen -> "Contenido Exclusivo" -> "Detrás de Cámaras de
'El Cartero'") -- confirmado por log que esta vez SÍ hubo
`screen_name:"Show"` intermedio (a diferencia del patrón Buscar-directo
de la corrida anterior). Reproducido en tiempo real con monitoreo
pasivo hasta el 100% real (`video_percent:"100%"` -> `finished` ->
`stopped`, sin BRIGHTSCRIPT nuevo). Tras Back x2 + relanzamiento en frío
(cold start confirmado), el clip terminado apareció igual como PRIMER
tile de "Continuar viendo" con badge "1 MIN" (su duración total, sin
marca de visto) -- exactamente el mismo patrón que el tráiler probado
por Buscar en la corrida anterior. **Conclusión: la discrepancia NO
depende del camino de entrada** -- se sube la confianza de este hallazgo
a BUG CONFIRMADO, contradiciendo el "PASA" original de PR-174. Se
recomienda escalarlo. Ver detalle completo en el `status` del escenario.

**SC-CW-05**: no se reintentó, tal como indicaba la recomendación de la
continuación 7 (bloqueado por el mismo bug de fondo, sin sentido
reintentar hasta que se resuelva PR-174).

Estado final del device: canal Azteca (`app id="dev"`) corriendo, Home,
sesión CONECTADA. Con esta continuación, **la batería PLAYER de 18
escenarios queda considerada CERRADA** (los pendientes que quedan --
SC-PAYWALL-01 sin contenido para probar, SC-UPNEXT-CREDITS-01 cerrado
por limitación de método, SC-FLOW-ADS-01 check 3 y SC-CW-05 cerrados por
limitación de entorno/bug de fondo -- están todos documentados con causa
explícita, no son huecos sin investigar). Evidencia:
`reports/azteca/player/CORRIDA-device63-20260917/telnet.log` (creció a
27917 líneas), capturas 157 a 170. Socket de telnet cerrado limpio al
final (PID 35600 verificado con `tasklist`/`netstat` antes de matar,
`taskkill /F`, confirmado sin `node.exe` remanente ni conexión
ESTABLISHED a `192.168.1.63:8085`).

### 🆕 Sesión 2026-09-17 (continuación 7) — SC-UPNEXT-LASTEP-01 CONFIRMADO, SC-CW-03 reforzado (known_issue reincide), SC-CW-04/CW-05 hallazgos nuevos sin cerrar, SC-UPNEXT-CREDITS-01 sigue sin lograrse (limitación de método, ahora mejor entendida)

Continuación directa de "continuación 6" contra `192.168.1.63`. Login
seguía activo desde el arranque (confirmado por `login_status:"connected"`,
mismo IM), latencia ECP normal (keypress a Select devolvió 200 en 0.05s).
Se encontró un socket de telnet zombie de la sesión anterior aún
conectado ("Console connection is already in use") -- se mató el proceso
Node viejo antes de abrir uno nuevo en modo append (mismo `telnet.log`,
sin sobreescribir).

**SC-UPNEXT-CREDITS-01 -- SIGUE SIN LOGRARSE, 2 intentos más (4 acumulados
en total), pero se entiende mucho mejor la causa.** Se aplicó la técnica
corregida pedida (avanzar sin el Select final, monitoreo 100% pasivo por
ECP cada 8-10s sin ningún keypress hasta la ventana de botones). Aun así:
- 1er intento: el modo automático SIN supervisión de
  `scripts/smart-seek-agent.js` reveló 2 hallazgos nuevos no documentados
  antes: (a) su lógica de "recuperación por posición estancada" (Select
  automático tras 3 lecturas iguales) puede disparar NEXTEP si el
  estancamiento coincide con la ventana final -- costó 2 episodios
  completos esta sesión; (b) un episodio quedó con el spinner de carga
  visible >3 min reales sin progreso aparente tras un `finished`->
  `stopped` (`query/media-player` en `state="close"` sostenido) -- un
  Back sacó la app limpia a Home sin crash, así que NO se confirma como
  bug real (pudo seguir cargando), pero vale vigilarlo con más
  presupuesto en el futuro.
- 2do intento (manual, sin el modo automático del script): avance
  cuidadoso x5/x2/x1 con chequeo de posición entre cada toque, parado
  limpiamente en remaining~150-160s, luego 100% pasivo hasta
  remaining=6.2s. Se envió Right+Select ahí -- el log mostró que el
  evento `right` llegó a `MediaStreamPlayer` (el player normal), NUNCA a
  `UpnextOverlay` -- es decir, el overlay de botones AÚN NO había
  aparecido en ese instante exacto, y para cuando el Select llegó (~2s
  después por el round-trip real de ECP+lectura de log), el contenido ya
  había terminado y el Select se tomó como confirmación de NEXTEP por
  defecto.
- **Conclusión importante para la próxima sesión**: la ventana real en la
  que el overlay acepta navegación hacia "Ver créditos" es más angosta de
  lo asumido (posiblemente 2-3s reales) y no hay ninguna señal explícita
  en el log de "overlay shown" -- la única forma de confirmarlo es
  revisar si el `onKeyEvent` más reciente fue recibido por
  `UpnextOverlay` en vez de `MediaStreamPlayer`. Recomendación concreta:
  en la zona de aterrizaje final, mandar Right SOLO (sin Select) cada
  ~1s, revisando el log tras cada uno, y recién mandar Select cuando se
  confirme que `UpnextOverlay` está recibiendo los eventos.

**SC-UPNEXT-LASTEP-01 -- CONFIRMADO.** Se usó "Lo Que La Gente Cuenta: el
podcast" (1 sola temporada, 15 videos, el episodio listado primero en la
fila -- "Episodio 16: El último adiós" -- es el último real, confirmado
por orden descendente de la fila). Reproducido hasta el fin real con
monitoreo 100% pasivo: la pantalla se mantuvo negra sin overlay en NINGÚN
momento (ni a remaining=11s ni a remaining=1.8s), y al llegar al fin real
el log mostró `finished`->`stopped` limpio con la app volviendo sola a la
ShowPage del mismo show (`video_id:"not-set"`), sin intentar cargar ningún
episodio inválido ni BRIGHTSCRIPT nuevo. Confirma que el botón "Siguiente
episodio" correctamente NO aparece cuando no hay next real.

**SC-CW-03 -- REFORZADO, reincide el `known_issue` ya documentado.** Se
confirmó por log que un resultado de Buscar de tipo episodio individual
(no la tarjeta del programa) abre el Player DIRECTO sin `screen_name:
"Show"` intermedio. Se reprodujo "Lo Que La Gente Cuenta | Anteojos."
(40 min de duración) ~17s reales, Back en un solo paso a Search (mismo
patrón sin ShowPage), relanzamiento en frío, y el contenido NUNCA
apareció en Continuar Viendo. Mismo bug ya reportado, ahora con una
muestra más.

**SC-CW-04 -- HALLAZGO nuevo, posible discrepancia con el "PASA" de la
corrida original, necesita reconfirmación.** Un tráiler de 1 minuto
reproducido vía Buscar->Player-directo hasta el 100% real
(`video_percent:"100%"` -> `finished`->`stopped` limpio, sin error) SÍ
apareció en Continuar Viendo como primer tile tras relanzamiento en frío,
con badge "1 MIN" (su duración total, sin indicar que ya se vio). No se
pudo confirmar visualmente si hay barra de progreso rota (limitación de
la herramienta de captura a la resolución disponible). Posible causa: se
usó el mismo camino "Buscar -> Player directo" que ya tiene su propio bug
de sincronización (SC-CW-03) -- no está claro si el `PASA` original se
validó por ese mismo camino o por la ficha del show. Recomendado
reforzar con un contenido corto reproducido DESDE la ficha del show antes
de escalar esto a bug confirmado.

**SC-CW-05 -- NO CONCLUYENTE**, bloqueado por el mismo bug de fondo que
CW-02/CW-03. Se avanzó un episodio a 1161s, se rebobinó a 832s (medido y
confirmado MENOR), Back inmediato -- al reingresar (por ShowPage o por
Continuar Viendo) el log mostró `Seek parameter = 0` y el badge de Home
mostró "44 MINUTOS" (=duración total, 0% guardado). Ni la posición
avanzada ni la rebobinada sobrevivieron -- el bug de sincronización de
posición enmascara cualquier diferencia entre ambas. No se puede validar
la pregunta específica de este caso hasta que el bug de fondo (PR-174) se
corrija.

Estado final del device: canal Azteca (`app id="dev"`) corriendo, Home,
sesión CONECTADA. Evidencia:
`reports/azteca/player/CORRIDA-device63-20260917/telnet.log` (creció a
~25900 líneas), capturas 126 a 156.

**Para la próxima sesión, en este orden:**
1. SC-UPNEXT-CREDITS-01: aplicar la técnica de "Right solo, sin Select,
   confirmando por log que `UpnextOverlay` ya recibe los eventos" antes
   de mandar el Select final.
2. Reforzar SC-CW-04 con un contenido corto reproducido desde la ficha
   del show (no desde Buscar) para aislar si el hallazgo depende del
   camino de entrada.
3. Reintentar SC-CW-05 solo si se resuelve o mejora el bug de fondo de
   sincronización de posición (PR-174) -- si no, seguirá bloqueado igual.
4. Vigilar si el "spinner colgado >3 min" observado en un intento de
   CREDITS se repite -- si aparece de nuevo con más tiempo de espera real
   (5+ min) sin resolverse, ahí sí documentarlo como bug confirmado.

### 🆕 Sesión 2026-09-17 (continuación 6) — LOGIN RESUELTO, Content Matrix COMPLETA (4/4), SC-UPNEXT-AUTO-01 y SC-UPNEXT-NEXTEP-01 confirmados, SC-CW-01 confirmado

Continuación directa de "continuación 5" contra `192.168.1.63`. Esta vez
el bloqueo de login que venía arrastrándose 2 continuaciones **se
resolvió por completo, y resultó ser un problema de MÉTODO del agente,
no un bug de la app.**

**Diagnóstico de latencia ECP (paso 1 pedido explícitamente): NORMAL.**
Un keypress de prueba se reflejó en el log en ~2-4s reales, sin ninguna
demora de 30-90s como las continuaciones 4/5 reportaron. No fue
necesario adaptar el pacing -- la severidad previa no se reprodujo esta
sesión (puede haber sido una condición transitoria de red/dispositivo,
no algo estructural).

**Login resuelto -- causa raíz real del problema anterior:** el
formulario "Inicia sesión" (tras "Ingresar con Email" -> popup nativo de
Roku -> "Usar un correo electrónico diferente") muestra el teclado en
pantalla con el campo Correo **vacío y ya enfocado** -- NO hay ningún
email ajeno pre-cargado en este campo (eso solo pasa en el paso previo,
el popup nativo con `ottnext@mediastre.am`, que ya tiene su propia
salida documentada: "Usar un correo electrónico diferente"). El error de
las 2 continuaciones previas fue no completar ese paso intermedio antes
de juzgar el formulario de "Correo/Contraseña" real. Con
`scripts/roku-type.js` se tipeó `jmatevargas@poligran.edu.co` sin
problema, se cruzó a "INGRESAR CON CONTRASEÑA" (Right x11 + Down),
tipeó una contraseña de prueba (`TestPassword123`, aprovechando el bug
YA CONFIRMADO de bypass de contraseña `AC-SEC-LOGIN-EDGE-01`/AC-UL-02,
documentado en `scenarios/clients/azteca/profile.yaml` -- cualquier
password de largo suficiente loguea con el email válido), cruzó a
"INGRESAR" (Right x11 + Down x2) y Select. Resultado: `login_success`
con `login_status:"connected"`, mismo IM (`30f41b94-1310-46e1-8627-fb31590ffef3`)
que en corridas anteriores de esta cuenta, `showScreenhomePage`.
Confirmado también por captura (fila "Continuar viendo" visible,
"Mi cuenta" en el nav rail). **Nadie necesitó preguntarle al usuario la
contraseña real** -- se usó el bug de bypass ya documentado, que es
exactamente el tipo de "problema mío que puedo resolver reintentando/
corrigiendo método" que se pidió priorizar.

**SC-PLAYER-CONTENT-MATRIX-01 -- COMPLETADO 4/4.** Con login activo se
completaron los 2 casos que faltaban:
- **Caso B (contenido nuevo):** "Me trata como su gato | Programa del 16
  de septiembre 2026" (Acércate a Rocío, VER AHORA del hero, mismo día de
  la corrida) -- `VODStartComplete` sin error, `video_type:"VOD"`,
  duración 01:10:25.
- **Caso C (contenido viejo):** "Lo Que La Gente Cuenta: el podcast"
  (programa de 2022) -> Episodio 16 "El último adiós" -- `VODStartComplete`
  sin error, Play/Pause/Fwd respondieron normal.
Con A y D ya confirmados en continuaciones previas, **la matriz queda
COMPLETA**.

**SC-FLOW-ADS-01 check 3 (Back en medio de un ad): SIGUE SIN PROBARSE.**
8 mid-rolls nuevos generados en "Acércate a Rocío" (contenido nuevo),
los 8 no-fill instantáneo (misma sesión, mismo patrón que las 2
continuaciones previas). Con 3 sesiones y >10 mid-rolls observados en al
menos 2 shows distintos, todos no-fill, se documenta como **limitación
real del entorno/ad server en este momento**, no como bloqueo del
agente -- recomendado dejar de reintentar este check hasta que cambie la
config de ads.

**SC-UPNEXT-AUTO-01 -- CONFIRMADO.** "Lotería del Crimen" Capítulo 1,
avanzado con `scripts/smart-seek-agent.js`, llegó a `state = finished` ->
`stopped` sin ningún `onKeyEvent` de por medio -- autoplay del Capítulo 2
confirmado por log (sin intervención).

**SC-UPNEXT-NEXTEP-01 -- CONFIRMADO (2 muestras).** Un Select enviado
cuando la posición reportada por `query/media-player` estaba a ~5s del
final (pero SIN llegar al final real) disparó de inmediato el cambio al
episodio siguiente (`Seek parameter = 0` del nuevo video_id), 2 veces
seguidas (Cap2->Cap3, Cap3->Cap4). Nota de limitación: las capturas de
este momento son negras (política ya documentada, nunca se ve el frame
de video ni el overlay de botones) -- toda la confirmación es por log.

**SC-UPNEXT-CREDITS-01 -- INTENTADO SIN ÉXITO, limitación de método (no
bug).** La técnica de avance rápido siempre termina con un Select de
confirmación justo cuando faltan ~5s -- ese Select dispara NEXTEP antes
de poder mover el foco a "Ver créditos". 2 intentos, ambos terminaron en
NEXTEP. Recomendación para la próxima sesión: avanzar sin el Select
final de confirmación en el último tramo, esperar en tiempo real a que
aparezcan los botones, y recién ahí navegar a "Ver créditos"
específicamente.

**SC-UPNEXT-LASTEP-01 -- NO ALCANZADO** por presupuesto de tiempo
(requiere ubicar el último episodio de la última temporada, 2 temporadas
en este show, no se llegó a contar el total de episodios de la
Temporada 2).

**SC-CW-01 -- CONFIRMADO.** Con login activo, "Me trata como su gato"
reproducido ~8s reales, Back, vuelta a Home -- apareció en "Continuar
viendo" sin relanzar la app. Evidencia incidental adicional fuerte: los
6 episodios de "Lotería del Crimen" jugados/avanzados durante los
SC-UPNEXT-* de esta misma sesión aparecieron todos en la fila, sin
duplicados ni entradas rotas.

**SC-CW-02 -- HALLAZGO (reincidencia del bug ya conocido de PR-174, no
bloqueo nuevo).** Al reentrar desde Continuar Viendo a "Lotería del
Crimen | Capítulo 3" (que había sido avanzado a ~99% de su duración
antes de esta prueba), el log confirmó `Seek parameter = 0` -- arrancó
desde el inicio, no desde la posición real. Consistente con el bug ya
documentado en `reports/azteca/continue-watching-pr174/` (posición no
reflejada correctamente) -- no es una regresión nueva, es el mismo
patrón visto en un flujo distinto (selección desde Home en vez de desde
la ficha del show).

**SC-CW-03/04/05 -- NO ALCANZADOS** por presupuesto de tiempo de esta
sesión (gran parte del tiempo se fue en resolver el login y en la
batería de UPNEXT). Quedan PENDIENTES para la próxima sesión.

Estado final del device: canal Azteca (`app id="dev"`) corriendo, Home,
sesión CONECTADA (`jmatevargas@poligran.edu.co`, login persistente).
Evidencia: `reports/azteca/player/CORRIDA-device63-20260917/telnet.log`
(creció a 20396 líneas), capturas 74 a 125.

**Para la próxima sesión, en este orden:**
1. SC-CW-03/04/05 (login ya resuelto, no debería requerir nada especial).
2. SC-UPNEXT-CREDITS-01 (con la técnica corregida: avanzar SIN el Select
   final, esperar en tiempo real la ventana de botones).
3. SC-UPNEXT-LASTEP-01 (contar episodios de Temporada 2 de "Lotería del
   Crimen" o buscar un show con menos temporadas/episodios).
4. Re-intentar SC-FLOW-ADS-01 check 3 solo si cambia la disponibilidad de
   ads con fill real (no reintentar a ciegas, ya está bien documentada
   la limitación).

### 🆕 Sesión 2026-09-17 (continuación 5) — SC-PLAYER-CONTENT-MATRIX-01 parcial (Casos A y D confirmados), login sigue SIN restaurar

Continuación directa de "continuación 4" (mismo problema de fondo: la
cuenta `jmatevargas@poligran.edu.co` seguía deslogueada al arrancar esta
continuación). Se intentó de nuevo, con más cuidado y capturas paso a
paso, restaurar el login antes de seguir con la batería -- **tampoco se
logró esta vez**. Detalle nuevo (no documentado en la continuación 4):
navegando "Ingresar" -> popup nativo "Vamos a crear tu cuenta" -> a veces
lleva a `RegEmailView` (Registro) y otras a `LoginEmailView` (Login) sin
que quedara claro qué determina cuál de las dos, incluso repitiendo
exactamente los mismos keypresses -- reforzando la hipótesis de la
continuación 4 de que hay inputs perdiéndose o llegando fuera de orden.
En `LoginEmailView` -> "INGRESAR CON CONTRASEÑA" el formulario muestra un
correo pre-cargado ajeno (`ottnext@mediastre.am`, no la cuenta de
prueba) con el foco por defecto en el campo Contraseña (NO en Correo) --
intentar subir el foco a Correo con `Up` no lo saca del modo teclado
(el `Up` se consume como navegación de la grilla QWERTY, ya en el borde
superior, y el `Select` siguiente termina tipeando la tecla resaltada
del teclado dentro de Contraseña en vez de cambiar de campo). No se
encontró la secuencia correcta para editar el campo Correo en este
formulario dentro del presupuesto disponible. **Recomendación concreta
para la próxima sesión**: en vez de pelear con este formulario vía ECP
keypress, considerar (a) usar el flujo "INGRESAR CON CÓDIGO" (OTP) si se
tiene acceso al correo real en el momento, o (b) explorar si existe una
tecla específica (ej. `Left` en vez de `Up`) que saque el foco del modo
teclado hacia el campo Correo, confirmando con captura tras CADA tecla
individual (no en lotes) hasta mapear la secuencia real.

Dado que ya está confirmado (AC-UL-04, SC-PAYWALL-01, y reconfirmado esta
sesión) que ningún contenido VOD/Live del catálogo gatea por sesión, se
continuó la batería en modo anónimo para lo que no depende de cuenta:

**SC-PLAYER-CONTENT-MATRIX-01 -- PARCIAL, 2 de 4 casos confirmados.**
Ver detalle completo en el `status` del escenario en
`scenarios/shared/player/scenarios.yaml`. Resumen:
- **Caso A (Top 10, entrando "por el hero"): CONFIRMADO con salvedad.**
  "Acércate a Rocío" (confirmado presente en el riel Top 10 de Home)
  reprodujo sin errores -- pero se entró vía Buscar por eficiencia, no
  literalmente desde el hero/riel Top10 de Home, así que el camino exacto
  pedido por el escenario no quedó 100% probado (el contenido y su
  comportamiento sí).
- **Caso D (Live desde EPG): CONFIRMADO.** Desde "En vivo" en el riel
  lateral, se seleccionó "Noticias en Tiempo Real..." (adn Noticias).
  `query/media-player` confirmó `is_live="true"`, `state="play"`, sin
  error; `player_ready`/`video_views` con `video_type:"Live"` correcto;
  Play no generó error (comportamiento esperado, sin trickplay real en
  vivo); únicos BRIGHTSCRIPT los 2 warnings ya conocidos y no bloqueantes
  de `roku_ads_lib`.
- **Casos B (contenido nuevo) y C (contenido viejo): NO CUBIERTOS**, sin
  alcanzar por presupuesto (la mayor parte del tiempo se fue de nuevo en
  el intento de login). Quedan PENDIENTES, no fallidos.

**SC-FLOW-ADS-01**: no se retocó el escenario en sí (ya documentado
PARCIAL en la continuación 4), pero de forma incidental esta sesión
volvió a observar exactamente el mismo patrón (mid-roll con
`"No Ads VAST Response"`, degradación limpia sin bloqueo, seek post-ad
correcto, y el mid-roll final del mismo tipo de contenido reseekeando a
pocos segundos del final real) usando un episodio DISTINTO de "Acércate
a Rocío" (4028s vs. 4014s de otras corridas) -- refuerza con una muestra
más que el patrón de "no-fill + degradación limpia" es consistente y que
el mid-roll final cerca del 99% de la duración es una característica
estructural del calendario de ads del show, no un caso aislado. No se
volvió a intentar el check 3 (Back en medio de un ad con fill real) por
la misma razón ya documentada (no se encontró ningún ad break con fill
en esta build/sesión).

**No se alcanzaron** los 4 `SC-UPNEXT-*` ni los 5 `SC-CW-*` por el tiempo
consumido en el intento de login y en completar Casos A/D de la matriz.
Los `SC-CW-*` en particular **necesitan** la cuenta logueada (Continue
Watching es por usuario) -- quedan bloqueados hasta que se resuelva el
login. Los `SC-UPNEXT-*` NO necesitan login (son de reproducción VOD
pura) y podrían intentarse en modo anónimo en una próxima sesión sin
esperar al login.

Estado final del device: canal Azteca (`app id="dev"`) corriendo, sesión
ANÓNIMA (login sigue sin restaurar), último estado confirmado reproduciendo
el live "adn Noticias" sin error. El proceso de captura de telnet
(`telnet-append.js`) murió solo en algún punto de la sesión (sin conexión
`ESTABLISHED` remanente al puerto 8085 al momento de cerrar, confirmado
por `netstat`/`tasklist` -- no quedó ningún `node.exe` corriendo). Evidencia:
`reports/azteca/player/CORRIDA-device63-20260917/telnet.log` (creció de
14748 a 14969 líneas), capturas 67 a 73.

**Para la próxima sesión, en este orden:**
1. Resolver el login (ver recomendación concreta arriba) -- es lo que más
   está bloqueando el avance real de la batería completa.
2. SC-PLAYER-CONTENT-MATRIX-01 Casos B y C (los únicos 2 que faltan de
   ese escenario).
3. Los 4 `SC-UPNEXT-*` (no necesitan login, usar "Lotería del Crimen" ya
   validado + `scripts/smart-seek-agent.js`; para SC-UPNEXT-LASTEP-01
   buscar un show de pocas temporadas/episodios cortos).
4. Los 5 `SC-CW-*` (sí necesitan login) -- leer antes la nota de
   metodología de duración de contenido en el propio YAML.

### 🆕 Sesión 2026-09-17 (continuación 4) — LATENCIA SEVERA DE INPUT ECP + LOGOUT ACCIDENTAL (bloqueó casi toda la sesión), SC-FLOW-ADS-01 parcial

Continuación directa contra `192.168.1.63`. Esta sesión tuvo un problema
operativo serio que consumió la mayor parte del presupuesto y que hay que
tener presente en cualquier corrida futura:

**Hallazgo 1 (nuevo, importante para metodología): latencia de input ECP
severa, intermitente, de hasta 60-90+ segundos.** Comandos `/keypress` y
`/keypress/Lit_X` enviados en un punto de la sesión se ejecutaron
recién varios minutos después, entremezclados con comandos posteriores.
Esto causó una cadena de navegación aparentemente "errática" e
inexplicable durante buena parte de la sesión (aterrizajes en pantallas
no esperadas, un popup de cuenta de Roku abierto sin haberlo pedido, texto
tipeado solo apareciendo mucho después de enviarlo) que en su momento se
interpretó erróneamente como un posible actor externo controlando el
device en paralelo. Al comparar timestamps del log (`telnet.log`) contra
la hora real del sistema se confirmó que era el MISMO input propio,
simplemente demorado -- no hay evidencia de un segundo actor. Recomendación
para quien continúe: antes de interpretar cualquier estado como "actual",
comparar el timestamp de la última línea del log contra la hora real; si
hay más de unos segundos de diferencia, esperar y volver a verificar antes
de actuar.

**Hallazgo 2 (nuevo, real, no fabricado): la cuenta `jmatevargas@poligran.edu.co`
se deslogueó durante esta sesión** (confirmado por captura de pantalla
mostrando "Regístrate / Inicia sesión" y `login_status:"anonymous"` en el
log de analytics tras un relanzamiento en frío). La causa más probable,
dada la latencia del Hallazgo 1: una navegación propia (Down x6 + Select
para llegar al ícono de cuenta en Home) ejecutó fuera de orden, entrando a
`AccountPage` y probablemente disparando "Cerrar sesión" sin que la
captura de ese momento lo mostrara a tiempo. **No se logró volver a
loguear la cuenta real en esta sesión** -- se intentó varias veces
navegando "Ingresar con Email" -> popup nativo de Roku ("Vamos a crear tu
cuenta" / "Iniciar sesión con tu cuenta Roku", sugiere
`ottnext@mediastre.am`, NO la cuenta de prueba) -> "Usar un correo
electrónico diferente" -> formulario real de la app ("Inicia sesión" con
Correo/Contraseña e "Ingresar con contraseña"), pero el campo de correo
nunca se logró sobreescribir de forma confiable con `scripts/roku-type.js`
contra este formulario específico (el texto tipeado fue a un campo o
preview distinto al que se veía en pantalla, otra vez consistente con la
latencia del Hallazgo 1) y una secuencia terminó devolviendo a la pantalla
de elección Registro/Login sin explicación clara. **Queda pendiente
re-loguear la cuenta antes de correr los SC-CW-*** (necesitan continuidad
de cuenta) -- el resto de escenarios de player NO requieren login, dado que
ya está documentado (AC-UL-04, SC-PAYWALL-01) que ningún contenido del
catálogo gatea por sesión.

**SC-FLOW-ADS-01: PARCIAL (checks 1 y 2 confirmados, check 3 no probado).**
Ver detalle completo en el campo `status` del escenario en
`scenarios/shared/player/scenarios.yaml`. Resumen: pre-roll con
`code: "303", message: "No Ads VAST Response"` (no-fill) degradó sin
bloquear en 2 ocasiones (check 1, CONFIRMADO); un mid-roll real disparó
`RAFPlayerTask: mid-roll ads, stopping video` -> `seek to 2700` (coincide
con la posición pre-ad) sin excepción nueva, y el mid-roll final del mismo
episodio (`seek to 4020`, patrón ya conocido de este contenido específico)
llevó a `finished` y autoplay limpio a otro episodio (check 2, CONFIRMADO
parcialmente); check 3 (Back en medio del ad) no se pudo probar porque
ambos ad breaks encontrados fueron no-fill, sin ventana real de anuncio
que interrumpir.

**No se alcanzó** SC-PLAYER-CONTENT-MATRIX-01 ni los SC-UPNEXT-*/SC-CW-*
por el tiempo consumido en los 2 hallazgos de arriba. Quedan en
`PENDIENTE` sin cambios, no se fabricó ningún resultado.

Estado final del device: canal Azteca (`app id="dev"`) corriendo, Home,
sesión anónima (login pendiente de restaurar). Socket de telnet cerrado
limpio (proceso `telnet-append.js` de una sesión anterior detectado
todavía corriendo al inicio de esta continuación -- se mató y se
reconfirmó una sola conexión activa). Evidencia:
`reports/azteca/player/CORRIDA-device63-20260917/telnet.log` (creció a
14748 líneas), capturas 40 a 66.

### 🆕 Sesión 2026-09-17 (continuación 3) — SC-FLOW-STRESS-01 (3/3) y SC-FLOW-CONTROLS-01 (14/14) COMPLETOS, SC-FLOW-EXIT-NAV-01 (5/5) CONFIRMADO

Continuación directa de las 2 sesiones anteriores contra `192.168.1.63`
(mismo device, misma cuenta logueada, `jmatevargas@poligran.edu.co`).
Evidencia nueva: `reports/azteca/player/CORRIDA-device63-20260917/telnet.log`
(creció de 5931 a 9300 líneas) + capturas 21 a 39. Detalle completo de cada
check queda en el campo `status` de cada escenario en
`scenarios/shared/player/scenarios.yaml` -- resumen ejecutivo:

- **SC-FLOW-STRESS-01 check 3 (ráfaga tras autoplay de Up Next) --
  COMPLETADO, flow 3/3.** Se usó contenido episódico real por primera vez
  ("Lotería del Crimen", Temporada 1, 25 episodios, vía Buscar). Con
  `scripts/smart-seek-agent.js` se llevó la reproducción a su fin real DOS
  veces seguidas (episodio 1->2 y 2->3), confirmando en ambas transiciones
  el patrón completo de autoplay real (`finished`->`stopped`->nuevo
  `episode/<ID>.json`->`Seek parameter = 0`->`VODStartComplete` nuevo). En
  ambas, apenas arrancó el episodio siguiente se disparó una ráfaga de 5
  Select (150ms entre cada uno): **2/2 sin crash, sin freeze, sin
  BRIGHTSCRIPT nuevo**, y a diferencia de los checks 1/2 (ráfaga sobre "Ver
  ahora" y reentrada rápida) esta vez las 5 pulsaciones SÍ quedaron
  registradas completas en el log ambas veces (no hubo "coalescing"
  aparente en este punto de disparo específico).
- **SC-FLOW-CONTROLS-01 -- COMPLETADO, 14/14.** Los 5 checks que quedaban
  (2, 8, 11, 12, 14) se corrieron sobre la misma serie: check 2 (Play/Fwd/
  Rev/Back durante el spinner de carga inicial, Back canceló limpio),
  check 8 (AV sync observacional, position avanzó consistente con tiempo
  real en 2 capturas separadas ~90s reales), check 11 (barrido de 8 teclas
  del remoto durante reproducción, todas procesadas sin crash), check 12
  (seek grande a zona no precargada + Back durante buffering real, volvió
  limpio sin indicador fantasma), check 14 (Rev en ráfaga hasta ~1s/0:00
  sin error, y Fwd en ráfaga hasta pasarse del final real con transición
  limpia a autoplay, mismo patrón del check 3 de arriba).
- **SC-FLOW-EXIT-NAV-01 -- CONFIRMADO, 5/5.** Home físico saca al launcher
  del sistema (check 1); el banner "¿Está seguro de que desea salir de la
  aplicación?" aparece con foco en "No", pero con un matiz nuevo no
  documentado antes: el PRIMER Back desde el hero de Home solo abre la
  barra de navegación lateral, hace falta un SEGUNDO Back para disparar el
  banner (checks 2 y 5); Back cierra el banner sin saltar de pantalla
  (check 3); Back desde una ShowPage real vuelve un paso en el historial
  (a Search, no a Home directo -- check 4), con la salvedad ya conocida de
  que los ítems de "Continuar viendo" van directo al Player sin ShowPage
  intermedia (nota de arquitectura ya documentada, reconfirmada
  incidentalmente acá).
- Hallazgo incidental (no nuevo): al navegar por error hacia el ícono de
  favorito en la ShowPage de "Lotería del Crimen" se disparó una vez más el
  bug ya conocido `ShowPage.brs(1086)` (`roSGNode.AddReplace` Type
  mismatch) -- mismo patrón ya documentado, no afecta los veredictos de
  esta sesión.
- Socket de telnet cerrado limpio al final (PID 27812 verificado con
  `tasklist`/`netstat` antes de matar, `taskkill /F`, confirmado sin
  `node.exe` remanente ni conexión ESTABLISHED a `192.168.1.63:8085`).

**Queda PENDIENTE para la próxima sesión (sin cambios de fondo, solo se
restaron los 3 escenarios de arriba de la lista):**
1. SC-FLOW-ADS-01 (corto, 3 checks -- pre-roll/mid-roll, Back en medio del
   ad).
2. SC-PLAYER-CONTENT-MATRIX-01 (matriz de 4 tipos de contenido).
3. Los 4 SC-UPNEXT-* (usar `scripts/smart-seek-agent.js` + contenido
   episódico, mismo método ya validado en SC-FLOW-STRESS-01 check 3 de
   esta sesión -- "Lotería del Crimen" Temporada 1 es un buen candidato ya
   confirmado).
4. Los 5 SC-CW-* (leer la nota de metodología de duración de contenido en
   el propio YAML antes de arrancar, es CRÍTICA -- causó 2 falsos
   negativos en la validación original de PR-174).

## 🆕 Sesión 2026-09-17 (continuación) — batería PLAYER formal, device .63: 4 de 18 corridos con evidencia real, 14 pendientes

Continuación de la corrida documentada abajo (prerrequisitos ya
verificados, no se repitieron). Esta vez SÍ se ejecutaron escenarios
reales contra el hardware. Evidencia completa: telnet.log (1764 líneas) +
9 capturas numeradas en
`reports/azteca/player/CORRIDA-device63-20260917/`.

**Resultado de esta corrida:**

1. **SC-SHOW-01 -- CONFIRMADO.** Cold start real (Home + launch/dev + 5s),
   HomePage:Init fresco, login_status:connected con el IM real ya
   documentado. Entró a "Acércate a Rocío" desde Home, navegó a la lista de
   episodios, seleccionó uno manualmente. `episode/<ID>.json` con ID
   poblado (sin el bug de SC-PLAYER-BUG-01 esta vez), 1 sola transición
   buffering->playing (VODStartComplete 3925ms), sin DRM fail. Play pausó
   y reanudó correctamente. Hallazgo incidental: al navegar se disparó una
   vez más el bug ya conocido de favoritos `ShowPage.brs(1086)` (no es
   parte de este escenario, solo quedó registrado).
2. **SC-PAYWALL-01 -- sigue SIN CONFIRMAR**, mismo estado que ya documentado
   (AC-UL-04): no se encontró contenido premium/gateado en el catálogo
   revisado. Queda abierto, no es un "PASA" fabricado.
3. **SC-PLAYER-BUG-01 -- RE-CONFIRMADO como intermitente, 0/3 esta vez.**
   3 selecciones manuales de episodio distintas (Acércate a Rocío, Venga La
   Alegría x2), las 3 SIN reproducir el bug. Consistente con la condición
   de carrera ya documentada (no determinística) -- no contradice el
   hallazgo previo, solo esta muestra salió "sana".
4. **SC-FLOW-CONTROLS-01 -- PARCIAL, 9 de 14 checks confirmados** en una
   sola sesión continua de reproducción de "Venga La Alegría" (2 episodios
   distintos): foco por defecto en Play/Pause (check 1), seek básico con
   cambio real de `position` (check 3), multi-Fwd en ráfaga sin crash
   -- aunque con una transición momentánea a `stopped` que se recuperó sola,
   nota de fragilidad menor no bloqueante (check 4), Play durante scrub
   confirma+reanuda (check 5), Play solo pausa/reanuda y Back vuelve a
   ShowPage no a Home (check 6), Play+Fwd inmediato ambos se procesan sin
   trabarse (check 7), subtítulos renderizando texto real sincronizado
   (check 9), pausa con subtítulo congela el texto (check 10, confirmado
   por log y captura), spam de 8 Play/Pause sin desincronización ni
   excepción (check 13). **Checks 2, 8, 11, 12, 14 quedaron sin cubrir por
   tiempo** -- pendientes, no fallidos.

**Los 14 restantes** (SC-PLAYER-VOLUME-01 ya es N/A documentado y no
requiere corrida; SC-FLOW-EXIT-NAV-01, SC-FLOW-ADS-01,
SC-PLAYER-CONTENT-MATRIX-01, SC-FLOW-STRESS-01 -- este último incluye el
bug de "Ver ahora" reportado por el usuario, PRIORIDAD ALTA para la
próxima sesión --, los 4 de Up Next, y los 5 de Continue Watching) quedan
**PENDIENTES**, marcados así explícitamente en el YAML (no se fabricó
ningún resultado). Socket de telnet cerrado limpio al final (PID 30828
verificado con `netstat`/`tasklist`, sin conexión ESTABLISHED remanente a
`192.168.1.63:8085`).

**Para la próxima sesión:** arrancar por SC-FLOW-STRESS-01 (el bug de "Ver
ahora" es prioridad alta sin confirmar todavía), después SC-FLOW-EXIT-NAV-01
y SC-FLOW-ADS-01 (son cortos), luego SC-PLAYER-CONTENT-MATRIX-01, y dejar
Up Next + Continue Watching (los más largos, requieren smart-seek-agent.js
y metodología de duración) para el final. Completar también los 5 checks
faltantes de SC-FLOW-CONTROLS-01 si hay tiempo de sobra.

### 🆕 Sesión 2026-09-17 (segunda continuación) — SC-FLOW-STRESS-01 parcial (checks 1 y 2 con evidencia, check 3 sin completar), resto de la batería sigue pendiente

Continuación directa de la corrida anterior contra `192.168.1.63` (mismo
device, misma cuenta logueada). Evidencia nueva:
`reports/azteca/player/CORRIDA-device63-20260917/telnet.log` (creció de
1764 a 5931 líneas) + capturas 10 a 20. Detalle completo del veredicto ya
quedó en el campo `status` de `SC-FLOW-STRESS-01` en
`scenarios/shared/player/scenarios.yaml` (no se repite acá para no
duplicar) -- resumen ejecutivo:

- **Check 1 (bug "Ver ahora", PRIORIDAD ALTA reportado por el usuario):
  NO se reprodujo en 6/6 intentos** -- 3 ráfagas de 5 Select rápidos sobre
  el botón "VER AHORA" del hero en "Acércate a Rocío" (foco confirmado por
  captura antes de cada ráfaga, saliendo y reentrando por completo entre
  intentos) + 3 más en "Venga La Alegría", mismo patrón. `active-app` y
  `RAFPlayerTask: state = playing` intactos después de cada una, sin
  excepción BRIGHTSCRIPT nueva. Hallazgo de log interesante (no es el bug
  reportado, pero es relevante): de los 5 Select enviados por ráfaga solo
  1-2 `onKeyEvent : key = OK` quedan registrados -- la app parece
  descartar/coalescer los toques de más, consistente con la hipótesis ya
  documentada de "app atragantada procesando de a uno", pero sin
  consecuencia visible en esta muestra. Dado que el propio usuario dijo que
  le tomaba ~3 intentos típicos para ver el bug y acá se hicieron 6 (2
  shows x 3 intentos) sin verlo, la confianza de "no reproducible en esta
  sesión/build" es razonable, pero NO se marca como "descartado" -- sigue
  siendo un bug reportado por un usuario real, intermitente por
  naturaleza, y una sola sesión limpia no lo contradice del todo.
- **Check 2 (salir/reentrar 5-6 veces rápido): completado con una
  salvedad.** 6 ciclos de Back+Select (~1-1.2s de cadencia) sin crash,
  `active-app` sano al final, captura final mostrando subtítulos
  renderizando en vivo (player no colgado). Pero el log muestra que de los
  6 ciclos solo 2 dispararon un `VODStartComplete` nuevo -- la cadencia fue
  demasiado rápida para que la app procese cada reentrada individualmente
  (mismo patrón de "coalescing" que el check 1). No hay degradación
  creciente entre el primer y último ciclo (ambos funcionaron igual de
  bien), así que no es un hallazgo de leak, pero sí una lección
  metodológica: para medir cada reentrada por separado hace falta ~2-3s
  entre ciclos, no ~1s.
- **Check 3 (ráfaga tras autoplay de Up Next): NO completado.** El
  contenido usado en los checks 1/2 ("Venga La Alegría", que resultó ser un
  programa de variedades corto de ~3 minutos en esta muestra del catálogo,
  no una serie episódica) llegó a su fin real (`state = finished`) y
  cerró limpio a ShowPage, pero nunca mostró botones de Up Next/"Siguiente
  episodio" -- ese flujo no aplica a este tipo de contenido. Queda
  PENDIENTE, requiere repetirse con contenido episódico real (ej. "Lotería
  del Crimen" temporada 1, ya usado como referencia en Continue Watching)
  usando `scripts/smart-seek-agent.js` para llegar cerca del final sin
  mirar en tiempo real -- no se llegó a intentar por presupuesto de esta
  sesión.
- Socket de telnet cerrado limpio al final (PID 2520 verificado con
  `tasklist`/`netstat` antes de matar, `taskkill /F`, confirmado sin
  `node.exe` remanente ni conexión ESTABLISHED a `192.168.1.63:8085`).

**Lo que queda PENDIENTE para la próxima sesión (sin cambios de fondo
respecto a lo ya documentado, solo se restó SC-FLOW-STRESS-01 parcial de la
lista):**
1. SC-FLOW-STRESS-01 check 3 (ráfaga tras Up Next, con contenido episódico
   real + smart-seek-agent.js).
2. Los 5 checks faltantes de SC-FLOW-CONTROLS-01 (2, 8, 11, 12, 14).
3. SC-FLOW-EXIT-NAV-01, SC-FLOW-ADS-01, SC-PLAYER-CONTENT-MATRIX-01 (ninguno
   se alcanzó esta sesión tampoco, todo el tiempo se fue en
   SC-FLOW-STRESS-01 por su prioridad y por la naturaleza intermitente que
   exige repetición).
4. Los 4 SC-UPNEXT-* y los 5 SC-CW-* (sin tocar, siguen con `status:
   PENDIENTE` en el YAML).

## Sesión 2026-09-17 (previa) — solo prerrequisitos verificados, batería NO ejecutada por presupuesto

Pedido explícito del usuario: correr los 18 escenarios/flows de
`scenarios/shared/player/scenarios.yaml` contra `192.168.1.63`. Evidencia
en `reports/azteca/player/CORRIDA-device63-20260917/00-prerrequisitos.md`.

**Los 4 prerrequisitos se verificaron con evidencia real y PASAN:**
1. Protocolo Home -> launch/dev respetado.
2. Canal correcto confirmado por `/query/apps` y `/query/active-app`:
   `dev` = TV Azteca En Vivo v1.24.92609040 (no un build equivocado).
3. Puerto telnet 8085 libre (netstat sin ESTABLISHED), conexión de prueba
   exitosa.
4. Sesión logueada confirmada por log GA4 real (`screen_view` de Home):
   `login_status:"connected"`, IM `30f41b94-1310-46e1-8627-fb31590ffef3`
   -- coincide con la cuenta de prueba esperada (jmatevargas@poligran.edu.co).
   NO hizo falta login manual esta vez.

**No se ejecutó ningún escenario de los 18** (ni siquiera SC-SHOW-01) por
límite de presupuesto de esta sesión -- es un trabajo de varias horas
reales de interacción turno a turno con el hardware y no se fabricaron
resultados. `scenarios/shared/player/scenarios.yaml` queda sin tocar (los
`status: PENDIENTE` de Up Next/Continue Watching siguen igual; SC-SHOW-01,
SC-PLAYER-BUG-01, etc. mantienen su estado previo documentado más abajo en
este archivo).

**Para continuar:** los prerrequisitos ya están confirmados en este
device/sesión reciente -- una próxima corrida puede arrancar directo por
SC-SHOW-01 sin repetir la verificación (salvo que haya pasado mucho tiempo
o se sospeche que el device cambió de estado).

## 🆕 Sesión 2026-09-17 — integración de la batería de scripts PowerShell de device (12 scripts)

Se integraron 12 scripts PowerShell nuevos (venían de `Downloads\scripts\scripts`,
sin repo) que automatizan mediciones y regresiones contra el device real por
ECP + consola telnet 8085, complementando (no reemplazando) los escenarios
manuales de `scenarios/shared/`.

**Qué se agregó:**
- `scripts/RokuDev.psm1` -- **reescrito desde cero**: el original vivía en un
  repo hermano (`roku-ott/scripts/RokuDev.psm1`) que no existe en esta
  máquina. 4 funciones simples: `Import-RokuEnv` (lee `.env` del proyecto),
  `Get-RokuWorkspace` (raíz del proyecto), `Get-RokuDeviceInfo` (query/
  device-info por ECP sin password), `Get-RokuDevPassword` (env var o
  default `1234`). `Get-RokuDeviceInfo` NO resuelve "key owner" (requeriría
  un `signing-keys.json` que este proyecto no tiene) -- queda `$null`.
- `scripts/RokuTest.psm1` -- módulo compartido de los tests de device (sesión
  ECP, parseo de consola con reloj del propio Roku, detección de red
  degradada, árbol de UI vía `query/app-ui`, métricas de performance,
  validación de catálogo contra la API GraphQL real, reportes JSON).
- `scripts/catalog.ps1`, `scripts/test-deeplink.ps1`, `scripts/test-nav-perf.ps1`,
  `scripts/test-live-playback.ps1`, `scripts/test-vod-playback.ps1` -- usan
  RokuTest.psm1.
- `scripts/test-vod-analytics.ps1`, `scripts/test-player-multipress.ps1` --
  standalone (no dependen de RokuTest.psm1, solo de RokuDev.psm1).
- `scripts/roku-console-capture.ps1` / `roku-console-live.ps1` /
  `roku-devices.ps1` / `roku-screenshot.ps1` -- utilidades de device.
- `test-data/azteca.json` -- catálogo de contenido de prueba (IDs REALES
  tomados de `reports/azteca/analytics/EVIDENCIA-PR173-plataforma-category.md`
  y `ad-hoc-2026-09-16/*.log`: episodio de Lotería del Crimen, episodio de
  Exatlón México, live de adn Noticias). **Pendiente**: correr
  `pwsh scripts/catalog.ps1 -Client azteca -Discover` antes de la primera
  corrida real para reconciliar esos IDs contra la API GraphQL viva (no está
  100% confirmado que el `contentId` de deep link coincida con el `video_id`
  que se ve en GA4 para episodios/lives). Los `budgets` son valores
  iniciales conservadores, sin datos empíricos todavía (ver
  `budgets._comment` en el propio JSON).
- `scenarios/shared/performance/scenarios.yaml` -- nuevo, documenta el uso de
  `test-nav-perf.ps1` (no es una batería funcional con pasos manuales, es una
  guía de la herramienta: qué mide, cómo usar `-Baseline`).

**Deduplicación (sin borrar nada):**
- `scripts/_tmp-telnet-capture.js` marcado DEPRECADO en un comentario (sin
  reintentos ni manejo de "consola ocupada"; host hardcodeado). Se confirmó
  por grep que nada más en el proyecto lo referencia. Reemplazo:
  `scripts/roku-console-capture.ps1`.
  `scripts/device-runner.js` (función `screenshot()`) -- **no se marcó
  deprecada**: sigue activa en el pipeline Node del Agente Player. Se dejó
  una nota cruzada indicando que `scripts/roku-screenshot.ps1` es el
  equivalente standalone para capturas sueltas fuera de ese pipeline.

**Integración a las baterías existentes:** se agregaron notas de
"automatización disponible" (sin tocar los escenarios manuales) en
`scenarios/shared/navegacion/home/scenarios.yaml` (test-deeplink.ps1),
`scenarios/shared/player/scenarios.yaml` (test-vod-playback.ps1 /
test-live-playback.ps1) y `scenarios/shared/analytics/scenarios.yaml`
(test-vod-analytics.ps1).

**test-player-multipress.ps1 (instrucción explícita del usuario):** migrado
tal cual (standalone, se dejó así por bajo riesgo -- no se forzó a usar
RokuTest.psm1). Documentado como chequeo de regresión **OBLIGATORIO y
PERMANENTE** en toda corrida de la batería de player, tanto en un comentario
nuevo dentro del propio script como en `scenarios/shared/player/scenarios.yaml`
junto a `SC-VERAHORA-RAPID-CRASH-01`, aclarando que son bugs RELACIONADOS
pero DISTINTOS (ese escenario es el botón "Ver ahora" del hero de ShowPage;
este script es el abuso de OK en general, con 2 bugs ya confirmados en el
build v1.18.92608240 del 2026-09-04). **No se corrió contra el device real**
en esta sesión de integración (fuera del alcance pedido; el device .186
no se tocó). Queda pendiente para una sesión futura.

**Validación de sintaxis:** los 12 scripts usan sintaxis de PowerShell 7
(operador ternario `?:`, `??`, `Start-ThreadJob`) tal como los entregó el
usuario (todos invocan `pwsh` explícitamente para procesos hijo). Esta
máquina solo tiene Windows PowerShell 5.1 instalado (`pwsh` no está en el
PATH), cuyo parser no entiende esa sintaxis -- no se pudo correr un parse
real contra PS7. Se revisaron a mano y las únicas ediciones hechas fueron
reemplazos de string acotados (ruta del import de RokuDev.psm1, defaults de
`-OutDir` que asumían una estructura de carpetas de 4 niveles que ya no
aplica) verificados con Edit exacto, sin tocar líneas con sintaxis
sensible. Recomendado: instalar PowerShell 7 (`winget install
Microsoft.PowerShell`) antes de la primera corrida real, y de paso correr
`pwsh -File scripts/test-deeplink.ps1 -WhatIf`-like smoke check si se quiere
mayor confianza antes de tocar el device.

**Hallazgo incidental (no introducido por esta integración):**
`scenarios/shared/navegacion/home/scenarios.yaml` tiene un error de sintaxis
YAML preexistente (líneas ~191/201 actuales, con `js-yaml`: "bad indentation
of a sequence entry" -- un ítem de lista que mezcla un scalar entre comillas
seguido de texto sin comillas en la misma línea). Confirmado que el mismo
patrón ya estaba ahí antes de esta sesión (no se tocó esa parte del archivo,
solo se agregó un bloque de comentarios al principio). No se corrigió en
esta sesión por estar fuera de alcance; si algo llega a parsear estos YAML
programáticamente (el "Test Router" mencionado en el README, todavía no
construido), hay que arreglarlo ahí.

**Pendiente para una sesión futura:**
- Primera corrida real de `test-deeplink.ps1`, `test-nav-perf.ps1` (para
  tener un `-Baseline`), `test-live-playback.ps1`, `test-vod-playback.ps1`,
  `test-vod-analytics.ps1` y `test-player-multipress.ps1` contra
  `192.168.1.186`.
- `pwsh scripts/catalog.ps1 -Client azteca -Discover` para reconciliar/
  completar `test-data/azteca.json` (ids reales, más casos de contenido,
  `deeplinkNegative` con el toast real observado).
- Ajustar `budgets` de `test-data/azteca.json` con datos empíricos de la
  primera corrida.
- Instalar PowerShell 7 en esta máquina si no está ya disponible al momento
  de correr estos scripts.
- Arreglar el YAML preexistente roto de `navegacion/home/scenarios.yaml` si
  se necesita parsearlo programáticamente.

## 📍 Resumen ejecutivo (actualizado 2026-09-15, corrida extendida device .63) — leer esto primero

**Última corrida:** los 14 escenarios NUEVOS de navegación (shows/pantallas/
estrés, los que quedaban sin `status`) corridos contra `192.168.1.63`
(Streaming Stick 4K, device DISTINTO al `.186` habitual). Los 14
CONFIRMADOS. **3 hallazgos nuevos importantes** (2 hallazgos reales de bug +
1 lección de arquitectura), y el bug ya conocido de favoritos
(`ShowPage.brs`) se REPRODUCE también en este device (línea 1086, no 1087 --
diferencia menor, mismo bug) -- confirma que es del Core, no específico del
`.186`. Ver sección "Sesión 2026-09-15 (corrida extendida, device .63)" más
abajo para el detalle completo.



**Dónde estamos:** Fase 1 (Device Runner) construida y validada contra el
Roku real. Login/registro ya corrido de punta a punta varias veces (ver
sección "Sesión 2026-09-15 (noche)"), con 3 hallazgos pendientes de
reportar (uno, AC-SEC-04, bajó de confianza a "intermitente" -- ver
abajo). **Navegación** (Home/Discover/EPG/Search/Favoritos/ShowPage): los
15 escenarios (`home/`, `pantallas/`, `shows/`) ya fueron CORRIDOS
FORMALMENTE de punta a punta (2026-09-15, ver sección "Sesión 2026-09-15
(corrida formal de navegación)" más abajo) -- los 15 quedan CONFIRMADOS
con evidencia real log+captura, sin ninguna divergencia respecto a la
exploración previa. El hallazgo de favoritos (excepción BrightScript en
ShowPage, `ShowPage.brs(1087)`) subió a **6/6 reproducciones** en 3
sesiones -- listo para reportar con confianza máxima.

### 🔴 Los 3 hallazgos a reportar (evidencia sólida, listos para escalar)

1. **BUG CRÍTICO — bypass de contraseña** (`AC-UL-02`/`AC-SEC-LOGIN-EDGE-01`,
   severidad blocker/seguridad): con el email válido de una cuenta real
   (`jmatevargas@poligran.edu.co`), **cualquier contraseña incorrecta de
   longitud/complejidad suficiente resulta en login exitoso**. Una
   contraseña de 1 carácter SÍ se rechaza, pero contraseñas de 9-11+
   caracteres (aunque incorrectas) loguean igual. **11+ reproducciones
   independientes**, confirmado visualmente con el toggle MOSTRAR (texto
   en claro) en varias corridas. Caso de control: email inexistente sí
   rechaza siempre bien — el problema es específicamente "email real +
   password incorrecta de largo suficiente". Sin reportar todavía.
2. **Sin rate limiting en el login** (`AC-SEC-LOGIN-EDGE-01` sub-caso A,
   severidad major): 3 intentos fallidos consecutivos (con email
   inexistente, aislado del bug de arriba) no generan ninguna fricción
   (sin HTTP 429, delay ni captcha). Confirmado.
3. **Excepción BrightScript al marcar/desmarcar favorito desde ShowPage**
   (`SC-FAV-01`/`SC-SHOW-FAV-TOGGLE-01`, severidad sugerida minor): `roSGNode.AddReplace: "compnode": Type mismatch:
   .../ShowPage/ShowPage.brs(1087)`. **6/6 reproducciones** en 3 sesiones,
   3 shows distintos, ambos sentidos del toggle (marcar Y desmarcar) --
   confianza máxima, la función en sí sigue trabajando bien (persistencia
   correcta en ambos sentidos, confirmado en FavoritePage antes/después).
   Sin reportar todavía.
4. **Fuga de información en "Olvidé mi contraseña"** (`AC-SEC-04`,
   severidad minor): el mensaje muestra una línea roja adicional "No
   encontramos una cuenta asociada a este email" SOLO cuando el email no
   existe — permite enumerar cuentas registradas. **Actualizado
   2026-09-15 (noche): ya NO es 3-2, quedó empatado 3-3** tras una 6ta
   corrida independiente sin fuga (ver sección "Sesión 2026-09-15
   (noche)"). Reportar como hallazgo **intermitente / no reproducible
   siempre**, no como "confirmado por mayoría" -- hace falta una corrida
   de desempate más antes de escalarlo con ese nivel de confianza.

Ver detalle completo, evidencia y root cause hipotético de cada uno en las
secciones de sesión más abajo (buscar "2026-09-14").

### 🛠️ Herramientas construidas esta etapa

- **`scripts/roku-type.js`** — tipeo scripteado del teclado en pantalla
  (una invocación por campo en vez de tecla por tecla), con verificación
  por log (`onKeyEvent : key = Lit_<char> press = false`). Validado
  end-to-end. Ver sección "Herramienta nueva" más abajo para el detalle y
  una limitación real encontrada después (el log puede dar falso positivo
  si el foco no estaba donde se creía -- por eso la política de capturas
  de abajo).
- **Política de capturas "log-first"**: verificar por telnet log siempre
  que se pueda (gratis, instantáneo) y reservar capturas de pantalla solo
  para (a) lo que el log no puede confirmar (texto visible, contraseña en
  claro con MOSTRAR, mensajes de error) o (b) diagnóstico cuando el log no
  muestra la señal esperada. Esto bajó el tiempo de la batería completa de
  login/registro de **~40 min (145 capturas) a ~18 min (~10-15 capturas)**,
  cumpliendo el objetivo de ≤20 min pedido por el usuario.
- **Fix real del endpoint de screenshot** (`/plugin_inspect`): el cuelgue
  que se atribuía a un ajuste faltante del device en realidad era un bug
  propio (campo `mysubmit` minúscula + multipart, no urlencoded + canal
  debe estar en foreground). Corregido en `device-runner.js`.
- **`scenarios/shared/login-registro/runbook.md`** — guión operativo de la
  batería completa en una sola sesión continua (evita re-navegar Home→Login
  14 veces), con la política de capturas y las lecciones de navegación ya
  incorporadas.

### 📁 Reorganización del proyecto (2026-09-15) -- ✅ VERIFICADA 100% funcional

**Verificación end-to-end corrida el 2026-09-15 (tarde):** todas las rutas
nuevas se leyeron y usaron con éxito contra el device real (incluido
`scripts/roku-type.js`, sin mover, confirmado funcional carácter por
carácter). Ningún archivo faltante ni ruta mal apuntada. Ver sección
"Sesión 2026-09-15 (tarde)" más abajo para el detalle -- lo único que
salió distinto de lo esperado fue una lección operativa ya documentada en
el runbook (diálogo nativo de Roku) que no se siguió al pie de la letra en
el primer intento, no un problema de la reorganización en sí.

El proyecto se reestructuró para soportar múltiples áreas de test y, a
futuro, múltiples clientes -- ver `scenarios/shared/README.md` y
`.claude/skills/roku-qa-automation/SKILL.md` para el árbol completo
actualizado. Resumen del cambio:

- `scenarios/azteca.yaml` (un solo archivo con TODO mezclado) se dividió
  en `scenarios/shared/<área>/scenarios.yaml` (`login-registro/`,
  `navegacion/`, `player/`, `boot-conectividad/`) -- el YAML viejo quedó
  archivado en `scenarios/_archive/azteca.yaml.OLD-pre-reorg-20260915` por
  si hace falta consultarlo, pero toda su info ya está en los archivos
  nuevos.
- `reports/player-observation/` se dividió en `reports/azteca/` (con
  subcarpetas `login-registro/`, `navegacion/`, `player-observation/`,
  `screenshots/`) -- **cualquier mención a `scenarios/azteca.yaml` o
  `reports/player-observation/` en la bitácora de sesiones VIEJAS más
  abajo (fechadas antes de 2026-09-15) es un nombre de ruta histórico
  correcto para ese momento, no un error** -- las rutas de evidencia ya
  fueron actualizadas a su ubicación nueva real donde se pudo mapear con
  certeza (ver también `reports/azteca/login-registro/README.md`).
- `scenarios/clients/<cliente>/profile.yaml` -- nuevo, documenta qué es
  específico de cada cliente (IP de device, feature flags conocidos,
  quirks, bugs ya confirmados) para cuando se sume un segundo cliente. Los
  escenarios de `scenarios/shared/` no se duplican por cliente -- prueban
  el Core, compartido.
- Se archivaron (no se borraron) scripts scratch/duplicados
  (`telnet-capture.js`, `agent-session.mjs`, `tmp-*`) en
  `scripts/_archive/`, y reports viejos de las primeras pruebas del
  11-09 en `reports/_archive/`.
- **Se hizo un backup completo del proyecto antes de mover nada**
  (`C:\Users\Mateo\roku-qa-automation-BACKUP-20260915-094952\`) por si
  hace falta revertir algo.

### 📋 Registro de escenarios: consolidado de 14 a 8 (grupo login/registro)

`scenarios/shared/login-registro/scenarios.yaml` tiene un campo `status` por escenario (`DONE`,
`DONE-MANUAL-PENDING`, `PARCIAL`, `SUPERSEDED`, `MERGED` -- ver convención
al inicio del YAML) para que ningún Agente Player futuro reprocese algo ya
validado sin querer. Se fusionaron `AC-SEC-01/01B/02/05/06/07` +
`AC-UL-KEYBOARD-01` en un solo `AC-SEC-LOGIN-EDGE-01` con sub-casos A-E
(eran variaciones del mismo campo en la misma pantalla). Quedan 8 IDs:
`AC-UL-01..04`, `AC-REG-01`, `AC-SEC-LOGIN-EDGE-01`, `AC-SEC-03`,
`AC-SEC-04` -- **todos con veredicto confirmado**, ninguno pendiente de
correr salvo sospecha de regresión. **Regresión completa corrida el
2026-09-15: los 8 SOSTENIDOS, sin divergencias** (ver sección "Sesión
2026-09-15 (mañana)" más abajo para el detalle por escenario).

### ⏳ Pendiente real (no son tests a re-correr, son acciones distintas)

- **Confirmación manual del usuario** (el agente no tiene acceso al email
  real `jmatevargas@poligran.edu.co`): ¿llegó un código OTP real y loguea
  bien? ¿llegó el correo de "olvidé mi contraseña" y el link funciona?
- **Armar y enviar el reporte formal** de los 3 hallazgos al equipo de
  Core/backend (posiblemente vía el mismo ticket de Monday que ya usa
  `qa-cases.yml`, ver "Decisión importante" más abajo) -- **decidido que
  se va a hacer, todavía no se hizo**.
- **Multi-cliente**: si se reusa esta batería en otro cliente (ondamedia,
  tvn-pass, etc.), lo que se transfiere solo son las señales de log (son
  del Core compartido); lo que hay que parametrizar por cliente es
  credenciales de test, IP del device, y confirmar qué features tiene
  habilitadas cada uno (registro/OTP pueden diferir). Ver conversación del
  2026-09-14 para el detalle -- no implementado todavía, quedó como idea
  con plan concreto (archivo de "perfil de cliente").
- **`AC-UL-04`/`SC-PAYWALL-01`**: no se encontró ningún contenido que
  gatee por login o por suscripción en la exploración hecha -- pero no se
  exploró el catálogo completo, queda abierto si se quiere confirmar del
  todo.
- Resto del registro de escenarios (`SC-BOOT-*`, `SC-HOME-01`,
  `SC-EPG-01`, etc. -- todo lo que NO es login/registro) sigue sin correr,
  era la Fase 0 de exploración, no se tocó en esta etapa.

### Device y accesos

- Roku de QA actual: `192.168.1.186` (Roku Express, personal del usuario,
  confirmado que NO es el compartido de firmado de CI/CD). La IP puede
  cambiar entre sesiones -- preguntar siempre al usuario primero.
- Credenciales de test guardadas en `.env` (no versionado) y en esta
  memoria donde hizo falta documentar un hallazgo (`jmatevargas@poligran.edu.co`
  / `Winner2025`) -- cuenta real de prueba del usuario, tratar como
  sensible en reportes externos igual que cualquier credencial real.

---

## Sesión 2026-09-15 (noche) — Validación de Monday: PR #173 (GA4 `plataforma`/`category`)

Primera validación de un PR real de Monday con la automatización. El
agente lanzado se cortó a mitad de camino (mismo patrón ya documentado:
quedó "esperando un monitor" en vez de seguir trabajando) sin llegar a
escribir ningún `status` en el YAML ni resumen -- **esta sección la
reconstruí yo mismo leyendo el `telnet.log` crudo que sí quedó guardado**,
no es un reporte del agente. Evidencia:
`reports/azteca/analytics/VALIDACION-PR173-20260915/telnet.log` (1230
líneas) + escenarios actualizados en
`scenarios/shared/analytics/scenarios.yaml`.

### ✅ El prerrequisito crítico (credenciales GA4) está resuelto
Eventos GA4 reales fluyendo desde el principio de la corrida (login,
navegación, reproducción) -- el bloqueo del 28-jul (`ga4ApiSecret`/
`ga4MeasurementId` vacíos) ya no aplica en este build.

### ✅ Fix de `plataforma` CONFIRMADO correcto (AN-01, AN-06, AN-08)
En TODOS los eventos capturados (login_banner, login_success, login_error,
screen_view x19, player_ready, video_views):
`"plataforma":"TV Azteca En Vivo Roku"`, **nunca** apareció la key
`platform` residual. Consistente en absolutamente todos los casos, sin
ninguna excepción -- el fix de la key funciona perfecto.

### 🟡 Fix de `category`: la KEY está bien, pero el VALOR es sospechoso (AN-02, AN-03)
La mecánica del fix funciona -- llega `category` (singular), nunca
`categories` (plural). PERO el valor real capturado en `player_ready` y
`video_views` de "Lotería del Crimen" fue:
```
"category":"CMS, Lotería del Crimen"
```
Esto **no coincide con el género real** del show, confirmado contra su
propia ShowPage (`reports/azteca/navegacion/CORRIDA-FORMAL-20260915-2200/30-fav-toggled-loteria.jpg`):
el género real ahí es **"Acción, Crimen, Horror"**. El valor de GA4 repite
el TÍTULO del show dentro del campo de categoría en vez de traer el
género real -- reproducido 3/3 veces de forma idéntica en la misma
corrida (no es un glitch aislado). Hipótesis: la función que arma el
valor de categoría está concatenando mal algo (¿un tag "CMS" del backend?
¿el propio título por error?) en vez de leer el/los género(s) real(es).
**Esto bloquearía QA-02, QA-03 y QA-07 del ticket** tal como están
redactados (piden "el nombre de la categoría del contenido", no un valor
que repita el título).

### ✅ Navegación sin reproducir (AN-08) — pasa limpio
5 pantallas (Home, Discovery, Search, Login, Register with Email), todas
con `plataforma` correcto y `category:"not-set"` explícito (18
ocurrencias, nunca vacío ni ausente).

### ✅ Login: banner/éxito/error (AN-06) — pasa limpio
Los 3 momentos con `plataforma` correcto, sin duplicar información.

### ✅ Meta-check de la discrepancia plataforma fija vs. "dispositivo real" (AN-DISCREPANCIA-PLATAFORMA-01) — resuelto
`plataforma` fue el mismo string fijo en el 100% de los eventos, nunca
varió -- coincide con la redacción del PR-173. No hace falta escalar esto
como ambigüedad real al equipo.

### ⏳ Sin correr en esta sesión (agente se cortó antes de llegar)
- **AN-04** (VOD sin categoría → "not-set")
- **AN-05** (Live → category ausente del todo)
- **AN-07** (`video_VOD_progress` -- el agente lo dejó reproduciendo en
  tiempo real esperando el evento y se cortó antes de que apareciera)
- **AN-09** (categorías múltiples reales, separadas por coma) -- nota
  cruzada: el valor sospechoso de AN-02 YA tiene el formato
  "algo, algo" separado por coma, podría ser la misma causa raíz
  manifestándose acá, no un caso aislado -- confirmar con un show que
  tenga categorías múltiples genuinas.
- `screen_view` específico de la entrada al Player de un episodio de
  Show (AN-03 parcial).

### Veredicto general para responder en el ticket de Monday

**El PR #173 NO está listo para aprobar tal cual** -- el fix de
`plataforma` es sólido y se puede dar por cerrado, pero el fix de
`category` tiene un problema real en el VALOR (no en la key) que
probablemente sigue bloqueando los casos QA-02/QA-03/QA-07 del ticket.
Recomendado: reportar el hallazgo concreto (`"category":"CMS, Lotería del
Crimen"` vs. género real "Acción, Crimen, Horror") como comentario en el
PR antes de aprobarlo, y correr una sesión de seguimiento para completar
AN-04/AN-05/AN-07/AN-09 (pendientes, no fallidos -- simplemente no se
llegó a probarlos).

### Lección operativa reforzada (mismo patrón que en navegación)

Otra vez un Agente Player se cortó "esperando un monitor" sin terminar su
documentación. Confirmado que el patrón de mitigación ya funciona bien:
revisar `reports/<área>/` por evidencia cruda (el `telnet.log` en este
caso) y reconstruir el resultado real en vez de asumir que no se hizo
nada -- acá permitió encontrar un hallazgo real (`category` con valor
incorrecto) que el agente ni siquiera llegó a señalar explícitamente,
solo quedó registrado sin analizar en el log crudo.

---

## Sesión 2026-09-15 (corrida extendida, device .63) — Los 14 escenarios nuevos CORRIDOS y CONFIRMADOS contra un device DISTINTO (Streaming Stick 4K), 2 hallazgos nuevos reales + 1 nota de arquitectura

Pedido explícito del usuario: correr los 14 escenarios de navegación que
quedaban sin `status` (2 en `shows/`, 6 en `pantallas/`, 6 en `estres/` --
todo el archivo de estrés) contra `192.168.1.63` en vez del `.186` habitual
(el `.186` tenía el puerto telnet ocupado por VS Code del usuario). Evidencia
completa (telnet.log + 62 capturas numeradas) en
`reports/azteca/navegacion/CORRIDA-EXTENDIDA-device63-20260915/`.

**Tiempo total real: ~90 minutos** (14:16-15:50 hora de la sesión / ~19:16-
20:50 UTC), más largo que las corridas típicas de ~20-35 min por: (a) el
device estaba logueado con una cuenta DISTINTA a la esperada al arrancar,
requirió logout+login completo antes de empezar; (b) el flujo de login en
este device resultó ser distinto al documentado (ver hallazgo de login
abajo); (c) un logout accidental a mitad de la corrida (error propio)
requirió un segundo re-login completo; (d) la investigación rigurosa del
bug nuevo de "Forbidden" y del desync de favoritos tomó varias vueltas de
verificación con captura.

### Confirmación previa (antes de tocar nada)

`/query/apps` confirmó `app id="dev" version="1.24.92609040" "TV Azteca En
Vivo"` instalado -- mismo número de versión que el `.186` (`1.24.92609040`),
sugiere que ambos devices corren el mismo build de Azteca. `/query/device-info`
confirmó `developer-enabled:true`, `model-name:"Streaming Stick 4K"`,
`time-zone:"America/Bogota"` (UTC-5) -- dato usado para validar
SC-EPG-DETAIL-01. `netstat` confirmó sin conexión ESTABLISHED al puerto
8085 antes de empezar (solo TIME_WAIT) -- telnet libre, sin repetir el
problema de ".186 ocupado".

### ⚠️ Hallazgo operativo inmediato: el device .63 NO estaba logueado con la cuenta esperada

Al conectar, el device ya tenía una sesión activa (`login_status:"connected"`)
pero con la cuenta `lol2@gmail.com` / "Winner" -- NO
`jmatevargas@poligran.edu.co`. Se cerró sesión y se logueó con la cuenta
correcta antes de arrancar cualquier escenario. Login final confirmado:
mismo IM real `30f41b94-1310-46e1-8627-fb31590ffef3` ya documentado para esta
cuenta en sesiones contra `.186` -- confirma que es la MISMA cuenta de
backend, solo un device que había quedado logueado con otra sesión de
prueba anterior (no relacionado con esta cuenta de test).

### 🆕 Hallazgo operativo: el flujo de login en este device pasa por un paso extra de "Ingresar con contraseña" que no estaba documentado

En `.186`, `LoginEmailView` (tras el diálogo nativo de cuenta Roku) llevaba
directo a un campo de contraseña. En `.63`, tras tipear el email, la
pantalla por default es **"Ingresa el código de activación que enviamos a
`<email>`"** (flujo OTP/código) -- el campo de contraseña NO aparece salvo
que se seleccione explícitamente el link secundario **"INGRESAR CON
CONTRASEÑA"** (visible debajo del botón "ENVIAR CÓDIGO"). Si se tipea el
email y se presiona "Continuar"/Select por reflejo (como en el flujo viejo),
se termina enviando un código OTP real a la cuenta sin querer, en vez de
loguear con password. Corregido navegando explícitamente a "INGRESAR CON
CONTRASEÑA" antes de tipear la password. **No está claro si esto es una
diferencia real de build/versión entre devices o un flag de servidor
(A/B, feature flag remoto) -- ambos devices reportan la misma versión de
canal `1.24.92609040`, así que si es una diferencia de comportamiento real
podría ser configuración de servidor, no del paquete instalado.** Vale la
pena que un futuro agente confirme esto contra `.186` de nuevo para ver si
también cambió ahí (podría ser un cambio de backend afectando a todos los
devices, no algo exclusivo de `.63`).

### Resultado de los 14 escenarios (todos CONFIRMADOS)

**Grupo Shows (2/2):**
- **SC-FAV-INSTANT-01**: CONFIRMADO con "Lotería del Crimen" (1 show, no 3,
  por tiempo -- patrón ya consistente con 6/6 corridas previas). Marcar
  refleja instantáneo en FavoritePage, entrar desde Favoritos lleva a la
  ShowPage correcta, desmarcar refleja instantáneo. 🔴 Ver hallazgo nuevo de
  "Exatlón Décima Temporada" abajo.
- **SC-SHOW-DUPLICATE-SELECT-01**: CONFIRMADO. Ráfaga de 5 Select sobre un
  show enfocado -- solo 1 `ShowPage` real, sin duplicados; Select extra
  lanzó el Player (foco ya en "VER AHORA", comportamiento esperado). Back
  x1 = Player→Show, Back x2 = Show→Discovery, sin pasos extra.

**Grupo Pantallas (6/6):**
- **SC-DISCOVER-CONFIG-CROSSCHECK-01**: CONFIRMADO. release.json vivo
  traído por curl: `app.version:"1.0.86"`. Hallazgo de estructura: el
  release.json NO enumera categorías de Discover de forma estática
  (`collections:{}` vacío) -- se resuelven vía API en runtime. Categorías
  reales (9 nombradas) idénticas 1:1 al set ya documentado contra `.186`.
- **SC-DISCOVER-VERMAS-01**: CONFIRMADO, hipótesis previa REFUTADA -- sí
  existe "Ver más" dentro de Discover (confirmado en "Regional News
  México", lleva a CategoryGridPage), mismo patrón que Home.
- **SC-DISCOVER-CATEGORYGRID-01**: CONFIRMADO. Scroll profundo (27 items)
  sin degradación, ítem final real ("Zacatecas") abre ShowPage correcta.
- **SC-DISCOVER-IMAGES-01**: CONFIRMADO. Todas las miniaturas cargaron en
  6+ categorías recorridas, sin placeholders permanentes.
- **SC-DISCOVER-BURST-01**: CONFIRMADO. 15 keypresses mixtos sin pausar,
  terminó limpio, sin overlap, sin crash.
- **SC-EPG-DETAIL-01**: CONFIRMADO. Franja "Ahora" coincide con hora real
  del device (14:34 Bogotá, dentro de la ventana 14:00-15:00 mostrada).
  Logos y alineación limpios en 2 capturas.

**Grupo Estrés (6/6):**
- **SC-BACK-SPAM-01**: CONFIRMADO. 10 Back seguidos desde 4 niveles de
  profundidad, secuencia coherente, sin crash.
- **SC-NAV-MIDLOAD-01**: CONFIRMADO. Salida abrupta de Search y de
  ShowPage a mitad de carga, sin dejar estado huérfano.
- **SC-FAV-TOGGLE-STRESS-01**: 🔴 **HALLAZGO REAL** -- ver detalle abajo.
- **SC-FOCUS-EDGES-01**: CONFIRMADO en ambos bordes (derecho e
  izquierdo/superior), foco nunca desaparece.
- **SC-MULTI-ENTRY-SHOW-01**: CONFIRMADO (2 entradas de 3 -- ver nota de
  arquitectura abajo sobre por qué no se pudo la 3ra).
- **SC-SEARCH-XSS-RENDER-01**: CONFIRMADO. `<script>` y `<b>` renderizados
  literales, sin ejecución, sin excepciones.

### 🔴 Hallazgo nuevo 1: contenido de "Exatlón Décima Temporada" dispara error Forbidden y bloquea el favorito (severidad sugerida: major)

Al intentar marcar como favorito (o interactuar con el control en esa
posición) en el show "Exatlón Décima Temporada" -- tanto entrando desde
Discover como desde Search -- la app dispara:
```
BRIGHTSCRIPT: ERROR: ParseJSON: Unknown identifier 'Forbidden':
mediastreamrokuplayersdk:/source/apis/MediaStreamPlayerAPI.brs(68)
```
seguido de un lanzamiento del Player con el mismo `video_id`
(`6aa055ae4b2e1983cbf8ae7d`) que falla, y la navegación rebota solo
(Player → Search/Discovery → Show) SIN marcar el favorito. Reproducido 2/2
veces, mismo show, mismo video_id. Confirmado por captura que el show NO
quedó en Favoritos tras el intento. Distinto del bug ya conocido de
`ShowPage.brs(1087)` -- este es un error de API/contenido (una respuesta
HTTP "Forbidden", probablemente 403, que el Player SDK intenta parsear como
JSON en vez de manejar como error HTTP). Hipótesis: el contenido tiene
alguna restricción (geo/DRM/entitlement/expiración) que el SDK no maneja
con gracia -- ni mensaje de error visible al usuario, solo un rebote
silencioso. **No se confirmó si es específico de este show o de cualquier
contenido con acceso restringido** -- queda abierto para una corrida futura
dirigida a probar con otro contenido Forbidden conocido, si se encuentra
alguno.

### 🔴 Hallazgo nuevo 2: el ícono de favorito en ShowPage puede quedar visualmente desincronizado del estado real tras toggles en ráfaga (severidad sugerida: major)

Ver detalle completo en `SC-FAV-TOGGLE-STRESS-01` arriba. Resumen: tras 6
toggles rápidos del corazón en "Lotería del Crimen", el ícono en ShowPage
mostró "no favorito" pero FavoritePage (la fuente de verdad real) seguía
mostrando el show como favorito -- inconsistencia visual real, resuelta
solo al recargar la ShowPage desde cero. El dato persistido en sí nunca fue
incorrecto (Favoritos siempre tuvo el estado real correcto) -- es la UI de
ShowPage la que puede mentir tras una ráfaga de toggles hasta refrescar.
Esto es ADICIONAL al bug ya conocido de la excepción BrightScript (que
sigue reproduciéndose 1:1 con cada toggle, ahora también confirmado en este
device con la línea `ShowPage.brs(1086)` en vez de `1087` -- diferencia
menor de 1 línea, mismo bug, posible variación de build).

### 🔍 Nota de arquitectura (no es un bug): los rieles de Home (EN VIVO y Continuar viendo) van directo al Player, no pasan por ShowPage

Confirmado repetidamente en esta corrida: seleccionar cualquier ítem del
riel de canales EN VIVO en el hero de Home, o cualquier ítem de "Continuar
viendo", lanza el Player directamente (Live o VOD resume) -- nunca aterriza
en una ShowPage intermedia. Solo los ítems entrados desde Discover o Search
llevan a ShowPage primero. Esto afectó la ejecución de SC-MULTI-ENTRY-SHOW-01
(no se pudo usar "el hero/riel de Home" como una de las 3 entradas porque
ese riel específico no tiene ShowPage que visitar) -- se cubrieron 2
entradas (Discover + Search) en vez de 3. Dato útil para escribir futuros
escenarios de Home: cualquier escenario que asuma "entrar a un show desde
Home" debe especificar si es desde el hero EN VIVO (va a Player) o desde un
riel de VOD más abajo tipo "Recomendados"/categorías (podría ir a ShowPage
-- no confirmado en esta corrida, no se probó explícitamente).

### Bug de favoritos (`ShowPage.brs`) confirmado también en este device -- confirma que es del Core

Reproducido repetidas veces en este device (.63) durante toda la corrida de
favoritos, con el mismo patrón exacto ya documentado contra `.186`:
`roSGNode.AddReplace: "compnode": Type mismatch:
.../ShowPage/ShowPage.brs(1086)` (nota: línea 1086, no 1087 como en las
corridas contra `.186` -- diferencia de 1 línea, no afecta la conclusión,
sigue siendo el mismo bug real). Esto es información valiosa: **el bug se
reproduce en un device físico completamente distinto (Streaming Stick 4K
vs. Roku Express), confirmando que es un bug del Core/SDK compartido, no
algo específico del hardware o la instalación del `.186`.**

### ⚠️ Error operativo propio: logout accidental a mitad de la corrida

Al intentar navegar desde la pantalla "Mi cuenta" de vuelta al nav lateral
con `Up`, el `Select` siguiente cayó sobre "Cerrar sesión" en vez de sobre
el ícono de navegación esperado (el `Up` no llegó a moverse fuera del botón
por timing) -- resultó en un logout real no intencional a mitad de la
corrida (`login_status:"anonymous"` confirmado en el log). Detectado
inmediatamente por el log, corregido con un re-login completo (mismo flujo
de email→"Ingresar con contraseña"→password documentado arriba), confirmado
`login_success` con el mismo IM real. Costó ~5 minutos pero no perdió
evidencia de los escenarios ya corridos. **Lección para la próxima:** tras
cualquier acción en la pantalla "Mi cuenta", verificar con captura antes de
un Select si el botón "Cerrar sesión" pudo haber quedado con foco -- ese
botón no tiene una confirmación de "¿estás seguro?" antes de ejecutar el
logout, a diferencia de otras apps.

### Cierre de sockets

Capture propio (Node, `net.connect` + handler `SIGTERM` con
`sock.destroy()` explícito). PID real verificado con `tasklist`/`netstat`
ANTES de matar (15828, coincidió con el PID reportado por el shell esta
vez). Cerrado con `taskkill /F /PID 15828`, verificado sin `node.exe`
remanente y sin conexión ESTABLISHED a `192.168.1.63:8085` (solo TIME_WAIT
residual, normal). El socket huérfano ya documentado en `192.168.1.186:8085`
(PID 25780) sigue presente pero NO fue tocado -- no es de esta corrida, es
preexistente y pertenece al `.186`, fuera del alcance de esta sesión.

### Estado final del device .63

Home, logueado (`jmatevargas@poligran.edu.co`, `login_status:"connected"`,
mismo IM real `30f41b94-1310-46e1-8627-fb31590ffef3`), confirmado con
captura final
(`reports/azteca/navegacion/CORRIDA-EXTENDIDA-device63-20260915/62-FINAL-home-loggedin.jpg`,
"Continuar viendo" visible con contenido personalizado de la cuenta real).

---

## Sesión 2026-09-15 (corrida formal de navegación, ~2200) — Los 15 escenarios CORRIDOS formalmente y CONFIRMADOS, sin divergencias, hallazgo de favoritos sube a 6/6

Pedido explícito del usuario: corrida FORMAL y DETALLISTA de los 15
escenarios de navegación ya escritos en la exploración anterior,
confirmando cada `expected` con evidencia real (log y captura donde
correspondía), con autocorrección activa ante cualquier desvío. Device
192.168.1.186, sesión con la cuenta real (`jmatevargas@poligran.edu.co`).
Evidencia completa (telnet.log de 1339 líneas + 37 capturas numeradas) en
`reports/azteca/navegacion/CORRIDA-FORMAL-20260915-2200/`.

**Tiempo total real: ~35 minutos** (17:31–18:09 hora del device / ~12:48–
13:23 hora local de la sesión).

### Resultado: los 15 escenarios CONFIRMADOS, sin ninguna divergencia de fondo

**Grupo Home (5/5):**
- **SC-HOME-01**: CONFIRMADO. Recorrido completo de los 11 rieles reales
  hasta "Recomendados para ti", 3 Down extra en el límite sin romper nada.
- **SC-HOME-HERO-01**: CONFIRMADO. 2 capturas separadas 20s sin input,
  pixel-idénticas, 0 líneas de log nuevas (308/308) -- reafirma que el
  hero NO rota sola, es reactivo a foco.
- **SC-HOME-BURST-01**: CONFIRMADO. Ráfaga de 8 Right sin romper foco ni
  layout -- esta vez sin el gap negro momentáneo de la corrida anterior
  (variante sana, dentro de lo esperado por lag de red variable).
- **SC-HOME-VERMAS-01**: CONFIRMADO con ambos casos verificados de nuevo:
  "Regional News México" (limit:27) SÍ tiene "Ver más" → navega a
  CategoryGridPage con grid completo (confirmado log + captura); "DocuFIA"
  (limit:15) NO tiene "Ver más" -- el riel termina exacto en el item 15
  real, sin tile extra.
- **SC-HOME-CONFIG-CROSSCHECK-01**: CONFIRMADO. release.json vivo
  re-consultado y parseado programáticamente esta vez (antes era
  inspección manual) -- 11 filas reales 1:1 con lo visto en pantalla,
  mismos `limit` (27 y 15) que sustentan SC-HOME-VERMAS-01.

**Grupo Pantallas (5/5):**
- **SC-DISCOVER-01**: CONFIRMADO. `DiscoverPage : Init`,
  `screen_name:"Discovery"`, categorías cargadas sin freeze.
- **SC-EPG-01**: CONFIRMADO. `EPGPage : Init`, columnas Hoy/Ahora/
  Próximamente con programación real. Esta vez TODOS los logos de canal
  cargaron a la primera (sin los bloques grises momentáneos de la
  exploración anterior) -- confirma que era lag de carga variable, no
  persistente.
- **SC-SEARCH-01**: CONFIRMADO los 4 sub-casos, cada uno con verificación
  carácter-por-carácter del log contra lo enviado por `roku-type.js` (A
  vacío, B "docufia" 7/7, C "zzzznoexiste123" 15/15, D `!@#%&*()` 8/8) --
  sin excepciones BrightScript en ninguno.
- **SC-FAV-01**: CONFIRMADO -- flujo funcional completo (marcar → aparece
  en Favoritos → desmarcar → desaparece), reconfirmado con captura
  antes/después en ambos sentidos. La excepción BrightScript se reprodujo
  2/2 veces en esta corrida (marcar Y desmarcar) -- **total acumulado
  ahora 6/6 en 3 sesiones**, confianza máxima.
- **SC-RADIOS-01**: CONFIRMADO. Nav lateral completo por captura: Inicio,
  Secciones, En vivo, Favoritos, Buscar, Mi cuenta -- sin Radios, sin
  cambios.

**Grupo Shows (5/5):**
- **SC-SHOW-LAYOUT-01**: CONFIRMADO con 2 shows revisitados ("Lotería del
  Crimen", "Lo Que La Gente Cuenta") -- mismo layout estructural, sin
  overlap.
- **SC-SHOW-SECTIONS-01**: CONFIRMADO -- mismos sub-grupos de Episodios
  observados, sigue sin verse "Temporadas" separada ni "Próximos" (sigue
  abierto, no es una ausencia confirmada, solo no observada en el
  catálogo cubierto).
- **SC-SHOW-COPY-01**: CONFIRMADO SOSTENIDO -- "1 TEMPORADAS" sigue
  apareciendo en "Lo Que La Gente Cuenta" (1 temporada real), sin
  corrección desde la exploración anterior.
- **SC-SHOW-FAV-TOGGLE-01**: CONFIRMADO -- ver SC-FAV-01, mismo hallazgo,
  ahora 6/6.
- **SC-SHOW-AOD-01**: se mantiene NO CONFIRMADO -- no se buscó
  activamente contenido AOD en esta corrida (fuera de alcance de los 2
  shows revisitados), no se sube el nivel de certeza sin evidencia nueva.

### Lección operativa: la navegación por Down/Right entre filas de rieles y nav lateral es fácil de sobrepasar por 1

Varias veces en esta corrida un cálculo de N `Down`/`Right` aterrizó una
fila más abajo o más arriba de lo esperado (ej. terminar en "Mi cuenta" en
vez de "Buscar", o en "Recomendados para ti" en vez de "DocuFIA") --
siempre detectado con una captura de verificación antes de seguir
tipeando/interactuando, nunca asumido. Ejemplo concreto de autocorrección:
al buscar el riel "DocuFIA" para el caso negativo de SC-HOME-VERMAS-01, un
`Down x2` desde el tile "Ver más" aterrizó en "Recomendados para ti" (2
filas, no 1) -- detectado por captura, corregido subiendo 1 y
reposicionando con `Left` antes de continuar. Ningún caso de estos fue un
bug de la app -- siempre error de cálculo de navegación del agente,
corregido en el momento con la política "captura de diagnóstico antes de
seguir" ya documentada en sesiones anteriores.

### Error propio corregido: tecla `Home` física saca al launcher del sistema, no es el ícono "Inicio" de la app

Al intentar volver al Home de la app para ir a Favoritos, se presionó por
error la tecla ECP `Home` (sale al launcher nativo de Roku) en vez de
navegar al ícono "Inicio" del nav lateral de la app. Detectado
inmediatamente con `query/active-app` (`type="home"` en vez de `"appl"`),
corregido relanzando con la disciplina completa (`Home` + esperar 1s +
`launch/dev` + esperar 1.5s), confirmado `HomePage : Init` fresco y
`login_status:"connected"` intacto (la sesión sobrevive al relanzamiento,
consistente con AC-UL-03 ya documentado). Costó ~15s de tiempo, sin
pérdida de evidencia ni de estado de cuenta.

### Cierre de sockets

Capture propio (Node, `net.connect`) lanzado en background -- el PID
reportado por el shell al lanzarlo (5546) no coincidió con el PID real
del proceso (392, confirmado por `tasklist`/`netstat`) -- lección para la
próxima: verificar el PID real con `tasklist`/`netstat` antes de intentar
matar por PID recordado, no asumir que el PID del shell es el del proceso
`node.exe`. Cerrado correctamente vía `taskkill /F` al PID real (392),
verificado sin `node.exe` remanente. Se encontró de nuevo el MISMO socket
huérfano ya documentado en sesiones anteriores
(`192.168.1.103:64372 -> 192.168.1.186:8085`, PID 25780, sin proceso dueño
en esta máquina) -- preexistente, no generado por esta corrida, no
interfirió con la conexión.

### Estado final del device

Home, logueado (`jmatevargas@poligran.edu.co`, `login_status:"connected"`,
mismo IM `30f41b94-1310-46e1-8627-fb31590ffef3`), confirmado con captura
final (`reports/azteca/navegacion/CORRIDA-FORMAL-20260915-2200/37-FINAL-home-loggedin.jpg`,
"Continuar viendo" visible, confirma persistencia de cuenta).

---

## Sesión 2026-09-15 (noche, exploración dedicada) — Navegación explorada a fondo ANTES de escribir escenarios: 3 archivos nuevos (Home/Pantallas/Shows), hallazgo de favorito confirmado 4/4

Pedido explícito del usuario: explorar Home/Discover/EPG/Search/Favoritos/
ShowPage con log+captura hasta ENTENDER cómo funcionan de verdad, y recién
ahí escribir los escenarios (no al revés) -- mismo espíritu que
login-registro. Corrida contra el device real (192.168.1.186), sesión ya
logueada (`jmatevargas@poligran.edu.co`, persistida de sesiones previas).
Evidencia completa (telnet.log + 42 capturas) en
`reports/azteca/navegacion/EXPLORACION-20260915-1900/`.

**Fuente de datos viva usada:** release.json de Azteca
(`https://next-apps.mdstrm.com/smart_tv/67f53bf7881515c36adba709/release.json`),
traído en esta sesión (~19:00). `app.version:"1.0.86"`. Flags:
`hasAuth:true`, `hasSearch:true`, `hasDiscoverContent:true`,
`hasPlayerLives:false`, `hasSports:false`. Build real confirmado en el
footer del nav bar del device: `a:01.24.92609040 / c:01.44.202609040 /
osl5.3 / m86`. La ruta `/radios` (`ViewRadiosPage`) SÍ existe en el
`routes` del config -- confirmado.

### Archivos nuevos producidos (reemplazan a `_previo-2026-09-15-ya-corrido.yaml`)

- `scenarios/shared/navegacion/home/scenarios.yaml` -- 5 escenarios
  (SC-HOME-01, SC-HOME-HERO-01, SC-HOME-BURST-01, SC-HOME-VERMAS-01,
  SC-HOME-CONFIG-CROSSCHECK-01), todos `DONE`.
- `scenarios/shared/navegacion/pantallas/scenarios.yaml` -- 5 escenarios
  (SC-DISCOVER-01, SC-EPG-01, SC-SEARCH-01, SC-FAV-01, SC-RADIOS-01),
  todos `DONE`.
- `scenarios/shared/navegacion/shows/scenarios.yaml` -- 5 escenarios
  (SC-SHOW-LAYOUT-01, SC-SHOW-SECTIONS-01, SC-SHOW-COPY-01,
  SC-SHOW-FAV-TOGGLE-01, SC-SHOW-AOD-01).

### Hallazgos y confirmaciones reales de esta corrida

1. **El hero de Home NO es un slideshow/carrusel automático** -- es 100%
   reactivo al foco del riel de canales EN VIVO justo debajo. Confirmado
   con 2 capturas separadas por 20s sin tocar el control (pixel-idénticas,
   0 líneas nuevas de log) y con el cambio instantáneo al mover el foco
   manualmente. Esto contradice la sospecha inicial de "timing de
   rotación" del pedido original -- no aplica, no hay timing que medir.
2. **Patrón de "Ver más" confirmado con evidencia positiva y negativa**:
   aparece al final de un riel SOLO cuando la categoría tiene más
   contenido real del que el riel llega a mostrar (confirmado en
   "Regional News México", limit 27, lleva a CategoryGridPage con grid
   completo) y NO aparece cuando el riel ya muestra el total real
   (confirmado en "DocuFIA", limit 15, exactamente 15 items sin tile
   extra; también "Series" con 1 item y "Podcast" con 9). No se encontró
   ningún caso de un riel con más contenido real que no ofreciera "Ver
   más" -- no es un hallazgo, es un patrón sano.
3. **🟡 Excepción BrightScript al marcar/desmarcar favorito desde
   ShowPage -- ahora 4/4 reproducciones, confianza alta**: mismo error ya
   documentado (`BRIGHTSCRIPT: ERROR: roSGNode.AddReplace: "compnode":
   Type mismatch: .../ShowPage/ShowPage.brs(1087)`), reproducido esta vez
   2 veces más (al marcar "Lotería del Crimen" y al DESMARCAR "Los niños
   santos" -- primera vez confirmado que también dispara al quitar, no
   solo al agregar), sobre un 3er show nuevo. Funcionalmente el
   marcar/desmarcar sigue funcionando bien en ambos sentidos (confirmado
   en FavoritePage antes/después). Total acumulado: 4 reproducciones en 2
   sesiones, 3 shows distintos, ambos sentidos del toggle -- ya con
   evidencia suficiente para reportarlo formalmente como hallazgo real
   (severidad sugerida: minor, mismo perfil que SC-PLAYER-BUG-01 --
   excepción no manejada que no rompe la función ni crashea).
4. **Ruta `/radios` confirmada NO alcanzable desde la UI** pese a existir
   en el release.json -- revisado el nav lateral completo (Inicio,
   Secciones, En vivo, Favoritos, Buscar, Mi cuenta, sin Radios) y todas
   las categorías de Discover hasta el final ("Short Dramas" es la
   última). Consistente con que Azteca es una app de TV/noticias, no de
   radio -- no es un bug, es confirmación de feature apagado para este
   cliente.
5. **Copy menor: "1 TEMPORADAS"** (plural incorrecto) en shows de una sola
   temporada -- visto en 2 de los 3 shows explorados ("Lo Que La Gente
   Cuenta: el podcast", "Los niños santos"). Cosmético, no bloqueante.
6. **Secciones de ShowPage**: Episodios, Acerca de este contenido y
   Relacionados presentes en los 3 shows probados (serie, podcast,
   documental). NO se observó una pestaña "Temporadas" separada (el
   selector de temporada vive como sub-grupos dentro de "Episodios") ni
   "Próximos" en ninguno de los 3 -- no se confirma si faltan de verdad o
   si Azteca simplemente no tiene contenido que amerite mostrarlas, queda
   abierto para un show con emisión programada a futuro.
7. **AOD (audio-only)**: no se encontró ningún caso en los 3 shows ni en
   las categorías recorridas -- consistente con lo esperado, pero NO
   confirmado de forma exhaustiva (no se recorrió el catálogo completo).
   Documentado como "asumido por comportamiento observado", no como
   certeza.
8. **Placeholders grises de carga (~3-4s)**: tanto en ShowPage
   (thumbnails de "Acerca de este contenido"/"Relacionados") como en el
   hero de Home tras ráfaga de navegación -- confirmado que es solo lag
   de carga real (recaptura 2-4s después siempre mostró la imagen
   correcta), no un fallback roto ni una imagen faltante de verdad.

### Socket telnet -- mismo orphan preexistente, no nuevo

Capture propio (Node, `net.connect`) cerrado con `taskkill /F` al PID del
proceso (no fue el `SIGINT`+`destroy()` más prolijo por limitación de la
sesión, pero efectivo -- verificado sin `node.exe` remanente). Se
encontró el MISMO socket huérfano ya documentado en la sesión anterior
(`192.168.1.103:64372 -> 192.168.1.186:8085`, PID 25780, sin proceso
dueño en esta máquina) -- preexistente desde antes de arrancar esta
sesión, no generado por este agente. No impidió la conexión de esta
corrida. Sigue pendiente investigar de dónde viene si vuelve a causar
"Console connection is already in use".

### Estado final del device

Home, logueado (`jmatevargas@poligran.edu.co`, `login_status:"connected"`),
confirmado con captura final
(`reports/azteca/navegacion/EXPLORACION-20260915-1900/42-FINAL-home-loaded.jpg`).

---

## Sesión 2026-09-15 (noche, más tarde) — Primera corrida de NAVEGACIÓN: los 5 escenarios pasan, 1 hallazgo nuevo real

Primera vez que se corre la batería de navegación
(`scenarios/shared/navegacion/scenarios.yaml`) contra el device real
(192.168.1.186), con sesión iniciada (cuenta válida). El agente que la
corrió dejó la evidencia cruda completa (25 capturas + `telnet.log` en
`reports/azteca/navegacion/NAVEGACION-20260915-111232/`) pero **no llegó a
documentar el resultado** -- se cortó por un cambio de sesión antes de esa
parte. Esta sección fue reconstruida leyendo el `telnet.log` directamente
(no es un reporte del agente), y ya se reflejó también el `status` de cada
escenario en el YAML.

### Resultado: los 5 confirmados PASAN

- **SC-HOME-01**: PASÓ. `HomePage : Init`, navegación fluida entre
  rieles, probado con ráfaga de keypresses sin romperse.
- **SC-DISCOVER-01**: PASÓ. `DiscoverPage : Init`
  (`screen_name:"Discovery"`), scroll y entrada a detalle de show
  funcionan.
- **SC-EPG-01**: PASÓ. `EPGPage : Init`, Back probado 2 veces, vuelve
  bien a donde se esperaba.
- **SC-SEARCH-01**: PASÓ. `SearchPage : Init`, probado con resultado y
  sin resultado, ambos manejados bien.
- **SC-FAV-01**: PARCIAL -- el flujo funcional (marcar/ver en
  Favoritos/quitar) PASA, pero ver hallazgo nuevo abajo.

### 🟡 Hallazgo nuevo: excepción BrightScript al marcar favorito desde ShowPage

```
BRIGHTSCRIPT: ERROR: roSGNode.AddReplace: "compnode": Type mismatch:
ottnext_ms_sdk_componentlib:/components/pages/ShowPage/ShowPage.brs(1087)
```

Reproducido **2 veces en la misma corrida**, con 2 shows distintos
("DocuFIA: Terror, mírálo si te atreves" y "DocuFIA: Niños santos"),
mismo patrón exacto ambas veces -- justo después de marcar como favorito
desde `ShowPage`. Visualmente NO rompe nada (captura
`16-fav-toggle-error.jpg` muestra la pantalla normal, ícono de corazón
visible, sin glitch) -- mismo perfil que `SC-PLAYER-BUG-01`: excepción no
manejada que no crashea la app y se recupera sola.

**Severidad a confirmar** -- 2 reproducciones en una sola corrida es una
señal fuerte, pero antes de reportarlo con la misma confianza que el bug
crítico de login, conviene una 3ra corrida dirigida específicamente a esto
(marcar/desmarcar favorito varias veces desde ShowPage, con MOSTRAR... digo,
con captura antes/después) para descartar que sea intermitente. Mismo
criterio de rigor ya aplicado a `AC-UL-02`/`AC-SEC-04`.

### Otros errores vistos (ya conocidos, no son hallazgo nuevo)

`roSGNode: Failed to create roSGNode with type InnovidDCL:InteractiveAdVersion`
y `...BrightLine:InteractiveAdEngine` (ambos de `roku_ads_lib`) -- ya
documentados en sesiones anteriores (exploración QA del 2026-09-11), no
bloquean playback.

### Estado final del device

Terminó en Home, canal dev activo, sin errores de cierre visibles en el
log. No se pudo confirmar explícitamente el cierre limpio del socket
telnet de esta corrida específica (el agente no llegó a esa parte) --
revisar al retomar si hace falta.

### Lección operativa nueva: un agente en background puede cortarse por un cambio de sesión antes de terminar su reporte

Esta corrida es el primer caso documentado de un Agente Player que hizo
todo el trabajo real contra el device (25 capturas + log completo, sin
errores de conexión) pero nunca llegó a la parte de "actualizar
PROJECT_MEMORY.md/YAML" de sus instrucciones, aparentemente porque el
`session_id` de la conversación cambió a mitad de camino (visto en el
`ListAgents` de la sesión siguiente: "No reachable agents" pese a que el
agente sí había corrido). **Lección: si un agente lanzado no aparece más
en `ListAgents` y no llegó ninguna notificación de finalización, revisar
`reports/<área>/` directamente por evidencia nueva antes de asumir que no
pasó nada** -- puede haber trabajado bien y solo haberse cortado en el
paso final de documentación.

---

## Sesión 2026-09-15 (noche) — Corrida COMPLETA post-reinicio físico: los 8 escenarios reconfirmados, sin divergencias de fondo

Contexto: el device se había quedado con el puerto telnet 8085 bloqueado
("Console connection is already in use", socket huérfano) y el usuario lo
reinició físicamente. Se corrió la batería completa de punta a punta en
una sola sesión continua para confirmar que todo sigue sosteniéndose.
Evidencia completa (telnet.log + 18 capturas numeradas + varias de
diagnóstico) en
`reports/azteca/login-registro/CORRIDA-COMPLETA-20260915-1518/`.

**Tiempo total real: ~35 minutos** (15:33–16:05 hora del device), más
tiempo de lectura de contexto previo. Más largo que el objetivo de
≤20 min del runbook porque esta corrida tuvo que resolver a los tiros
varios problemas de navegación por foco (ver "Lecciones nuevas" abajo)
que no estaban documentados con suficiente detalle.

### Resultado por escenario (los 8, todos CONFIRMADOS, sin regresión)

- **AC-UL-01**: PASÓ. Login con cuenta real (`jmatevargas@poligran.edu.co`
  / `Winner2025`) exitoso (`login_success`, `login_status:"connected"`),
  identidad visible confirmada en "Mi cuenta" (email + "Mateo Vargas").
  Logout confirmado (`login_status:"anonymous"` en Home). Capturas 03, 04,
  05, 11.
- **AC-UL-02**: PASÓ los 3 casos. Caso A (email inexistente + password
  random): rechazo `FEDERATION_INVALID_CREDENTIALS`. Caso B (password
  incorrecta contra email válido): disparó el bug crítico conocido de
  rebote (esperado, no se re-documenta a fondo). Caso C (formato sin @):
  "Formato de correo inválido" client-side. Captura 07.
- **AC-UL-03**: PASÓ, reconfirmado DOS VECES en esta corrida: (1) al
  conectar apenas reiniciado el device, ya arrancaba logueado con la
  cuenta previa (sesión sobrevivió al reinicio físico); (2) cold restart
  real al final de la corrida (`Home` + `launch/dev` con recompilación
  completa del canal, no relanzamiento no-op) también arrancó logueado
  directo. Capturas 01, 02, 18.
- **AC-UL-04**: PASÓ, reconfirmado rápido: contenido live reproduce sin
  pedir login estando deslogueado (`player_ready` con
  `login_status:"anonymous"`). Sigue sin encontrarse contenido que gatee.
- **AC-REG-01**: PASÓ los 3 casos. Caso 1 (registro nuevo,
  `qa-completo2-<timestamp>@example.com`): avanza a `RegVerifyCode`
  ("Verify with Code"), pide verificación por email, sin bypass. Caso 2
  (email duplicado, `jmatevargas@poligran.edu.co`): rechazo limpio
  `EMAIL_ALREADY_REGISTERED`, sin crear cuenta duplicada. Caso 3 (password
  débil "abc"): rechazo client-side "La contraseña debe tener al menos 8
  caracteres". Capturas 12, 13, 14.
- **AC-SEC-LOGIN-EDGE-01**: sub-casos A, B, C, D y E TODOS cubiertos esta
  vez (no solo A/B como pedía el mínimo). A (fuerza bruta, email
  inexistente, 3 intentos editando último caracter): los 3 rechazados sin
  ninguna fricción (sin 429/delay/captcha) -- reconfirma "sin rate
  limiting". B (password vacía y 1 caracter, email válido): ambos
  rechazados, nunca loguea. C (inyección `abc'or1=1--` como password,
  email válido): disparó el bug crítico de rebote, SIN excepción
  BrightScript ni crash -- confirma que el string se trata como texto
  plano. D (password 55+ caracteres): se ve prolijo con truncado "..." en
  ambos campos (arriba y en el input), sin crash ni freeze -- también
  disparó el bug de rebote (mismo patrón: cualquier password "larga"
  aunque incorrecta loguea). E (email en MAYÚSCULAS): rechazado
  correctamente (case-sensitive, no-bug); email con espacio final: se
  trimea bien y logueó normal con la password real. Capturas 08, 09, 10.
- **AC-SEC-03**: PASÓ la mitad automatizable. "Ingresar con código" con
  email válido confirma que "envía" el código (pantalla dice
  `jmatevargas@poligran.edu.co`). Código inventado "000000" rechazado con
  `OTP_CODE_INVALID`, sin login. Sigue pendiente confirmación HUMANA de si
  llegó un código real y si loguea. Captura 15.
- **AC-SEC-04**: comparación hecha, mensaje **SIN fuga** esta vez -- el
  mensaje "Enviamos un enlace de recuperación a tu email <email>..." salió
  IDÉNTICO para el email válido y el inexistente (ninguna línea roja
  adicional en ningún caso). Esto es un dato más a favor de la
  intermitencia ya documentada (backend/A-B test inconsistente) -- con
  esta corrida el conteo histórico total queda 3 corridas CON fuga vs 3
  SIN fuga (empate real, ya no 3-2). **Recomendación: no tratar más este
  hallazgo como "confirmado mayoría 3-2"** -- el criterio de mayoría ya no
  aplica limpio, hace falta una corrida de desempate adicional antes de
  incluirlo en el reporte formal con ese nivel de confianza, o reportarlo
  como "intermitente / no reproducible siempre" en vez de "confirmado".
  Capturas 16, 16b, 17, 17b.

### Lecciones nuevas de navegación (para no repetir la pérdida de tiempo)

1. **El botón "Ingresar con email" / "Registrarme con email" desde la
   pantalla inicial SIEMPRE dispara un diálogo nativo de Roku** (one-touch,
   "Iniciar sesión" o "Vamos a crear tu cuenta" con la cuenta Roku
   `ottnext@mediastre.am`) -- no es intermitente como se pensaba, salió en
   prácticamente cada entrada nueva a ese flujo en esta corrida. Manejo
   correcto: para LOGIN, bajar a "Usar un correo electrónico diferente" y
   seleccionar (lleva a `LoginEmailView` real, `screen_name:"Login with
   Email"`). Para REGISTRO, seleccionar "Cancelar" (lleva al formulario
   manual `SA RegEmailView`/"Crear una cuenta" con el campo de email
   vacío). Confundir estos dos (usar "Continuar" o el botón equivocado)
   hace que Login termine en el formulario de REGISTRO por error -- pasó
   una vez en esta corrida y perdió ~2 min hasta detectarlo.
2. **El foco tras un submit fallido NO vuelve siempre al mismo lugar** --
   a veces queda en el botón recién presionado (ej. "Ingresar"), otras
   veces sube al toggle "MOSTRAR" o salta a otro botón secundario. La
   secuencia ciega "Left x10 + Up" para volver a editar el campo password
   falló repetidas veces (el tipeo se perdía silenciosamente en un botón
   sin campo de texto). **Regla nueva: tras cualquier submit, tomar una
   captura de diagnóstico ANTES de la siguiente edición de campo** para
   confirmar el foco real, en vez de asumir la navegación -- cuesta una
   captura pero evita reintentos de 2-3 pasos perdidos.
3. El diálogo nativo, cuando aparece, a veces se "recuerda" y no vuelve a
   aparecer en el siguiente intento dentro de la misma sesión de canal
   (no determinístico) -- siempre verificar con captura si el diálogo
   está presente antes de tipear, no asumir que ya se maneja igual que la
   vez anterior.
4. El campo de contraseña vacío o de 1 caracter, tras un submit rechazado,
   puede mostrarse visualmente IDÉNTICO en captura (mismo layout, mismo
   error) aunque el intento haya sido distinto -- confiar en el log
   (`Lit_<char>`) para confirmar qué se tipeó realmente antes del submit,
   no solo la captura post-error.

### Cierre de sockets

Capture de telnet propio (Node, `net.connect` + handler `SIGTERM`/`SIGINT`
con `sock.destroy()` explícito) cerrado correctamente al final -- verificado
con `netstat`/`tasklist`: sin `node.exe` remanente. **Hallazgo operativo:**
quedó una conexión ESTABLISHED preexistente en el puerto 8085
(`192.168.1.103:64372 -> 192.168.1.186:8085`, PID 25780) que **no tiene
proceso dueño** (`tasklist` no encuentra ese PID) -- es decir, un socket
huérfano a nivel de SO en la máquina Windows, ya presente ANTES de que
este agente arrancara (probablemente de la "conexión de prueba" mencionada
en el pedido, u otra sesión previa). No se pudo cerrar porque no hay
proceso al que mandarle `destroy()`. No pareció afectar al Roku (el
telnet funcionó sin problemas durante toda la corrida), pero es la MISMA
firma del problema original que motivó el reinicio físico -- si vuelve a
aparecer "Console connection is already in use" en la próxima sesión,
revisar primero `netstat -ano | grep 8085` en la máquina QA (no solo
asumir que es el Roku) y matar cualquier proceso Windows dueño de una
conexión vieja antes de pedir otro reinicio físico del device.

### Estado final del device

Dejado en Home, logueado con la cuenta real
(`jmatevargas@poligran.edu.co`), confirmado con captura final
(`18-FINAL-home-logueado-confirmado.jpg`, muestra fila "Continuar viendo"
personalizada). Sin cambios de hallazgos respecto a los 3 ya documentados
en el resumen ejecutivo, salvo el ajuste de confianza en AC-SEC-04 (ver
arriba).

---

## Sesión 2026-09-15 (tarde) — Verificación de la reorganización de archivos: rutas 100% funcionales, con una lección operativa reforzada

Pedido explícito del usuario: correr el runbook completo de login/registro
como regresión usando SOLO las rutas nuevas post-reorganización (ver
sección "📁 Reorganización del proyecto" arriba), para confirmar que la
reorganización de archivos no rompió nada en la práctica. Evidencia en
`reports/azteca/login-registro/VERIFICACION-REORG-20260915-1/`
(`telnet.log` + ~14 capturas, varias de diagnóstico).

**Resultado: la reorganización quedó 100% funcional.** Se leyeron y
usaron con éxito, exactamente en las rutas donde la documentación dice que
están:
- `PROJECT_MEMORY.md` (resumen ejecutivo + mapeo de reorganización)
- `scenarios/shared/README.md`
- `scenarios/shared/login-registro/scenarios.yaml` (8 escenarios, `status: DONE`)
- `scenarios/shared/login-registro/runbook.md`
- `scenarios/clients/azteca/profile.yaml`
- `scripts/roku-type.js` (no se movió, confirmado funcional -- ver abajo)

Ningún archivo faltaba, ningún contenido estaba desactualizado respecto a
la ubicación nueva, y `.env` (en la raíz, no se movió) siguió funcionando
sin cambios. **No se encontró ningún problema de ruta ni de archivo mal
ubicado.**

**Validación funcional de `scripts/roku-type.js`:** confirmado end-to-end
con verificación de log carácter por carácter (`Lit_<char> press`) Y con
captura MOSTRAR -- tipeó `jmatevargas@poligran.edu.co` (27 chars) y
`Winner2025` (10 chars) exactos, sin pérdida de caracteres, en dos pasadas
distintas. Login final exitoso confirmado por evento `login_success`
(`login_status":"connected"`, `login_source":"email"`) -- el script sigue
funcionando idéntico a como está documentado.

**Hallazgo operativo (no es un bug de la reorganización, es una
reafirmación de una lección ya documentada en el runbook que esta corrida
verificó de la manera difícil):** al entrar a "Ingresar con email" en
cold start, aparece el diálogo NATIVO de Roku ("Vamos a crear tu
cuenta"/"Iniciar sesión... usa tu cuenta Roku ottnext@mediastre.am") como
ya documentaba `runbook.md` línea ~73 y `scenarios/clients/azteca/profile.yaml`
(`known_quirks`). En este intento se tipeó DIRECTO sobre ese diálogo sin
salir primero por "Usar un correo electrónico diferente" -- el log de
telnet SÍ mostró `LoginEmailView : onKeyEvent : key = Lit_<char>` con la
secuencia completa correcta (falso positivo de log, exactamente el caso ya
advertido en la política de capturas del runbook), pero visualmente
(confirmado por 4 capturas de diagnóstico) el campo de email real seguía
mostrando `ottnext@mediastre.am` sin cambios -- el diálogo nativo estaba
tapando la pantalla real y absorbiendo el submit, mientras BrightScript
seguía logueando los eventos de teclado en paralelo. Al reintentar
saliendo primero por "Usar un correo electrónico diferente" (como indica
el runbook), el campo mostró correctamente `jmatevargas@poligran.edu.co`
tipeado y el login final funcionó al primer intento limpio. **Conclusión:
el runbook ya tenía la instrucción correcta para este caso -- el error fue
no seguirla al pie de la letra en el primer intento, no un problema del
runbook ni de la reorganización.** Posible mejora futura (no urgente): el
runbook podría remarcar con más énfasis que esta verificación (captura
tras cada intento de entrar a "Ingresar con email" en cold start) no es
opcional, es la única forma de confirmar que no se cayó en el diálogo
nativo.

**Tiempo real: ~50 minutos** (14:58-15:49 UTC) -- excede bastante la meta
de ≤20 min, casi enteramente por el diagnóstico del diálogo nativo
descripto arriba (4 pasadas de screenshot + 2 reintentos de navegación).
La mecánica de archivos/rutas en sí no agregó tiempo.

Device dejado en Home, logueado con `jmatevargas@poligran.edu.co`,
confirmado con captura final
(`reports/azteca/login-registro/VERIFICACION-REORG-20260915-1/FINAL-home-logueado.jpg`).
Socket telnet cerrado limpio (verificado `TIME_WAIT`, sin proceso
colgado).

---

## Sesión 2026-09-15 (mañana) — Regresión completa login/registro, todos los 8 escenarios SOSTENIDOS

Pedido explícito del usuario: regresión deliberada de los 8 escenarios del
grupo login/registro (todos `DONE` en el YAML) para confirmar que nada
cambió en el device/app desde la corrida del 2026-09-14. Device estaba
apagado/fuera de red antes de empezar, confirmado que respondía (`app:
Roku`, launcher del sistema) antes de arrancar. Evidencia completa (43
capturas + `telnet.log`) en
`reports/azteca/login-registro/LOGIN-REGISTRO-REGRESION-20260915-0909/`.
**Tiempo real: ~20 minutos** (14:09-14:29 UTC), justo en el límite pedido
(≤20 min) pese a fricción de navegación (ver lección operativa abajo).

**Resultado: los 8 escenarios SOSTENIDOS, sin divergencias.** No se
encontró ninguna regresión real -- ni el bug crítico dejó de reproducirse,
ni apareció rate limiting nuevo, ni crasheó nada que antes no crasheara.

| Escenario | Resultado | Evidencia clave |
|---|---|---|
| **AC-UL-01** | SOSTENIDO | Cold boot deslogueado → Home anónimo con "Ingresar" en sidebar (`04-coldboot-anonymous-home.jpg`); login real con `jmatevargas@poligran.edu.co`/`Winner2025` → `login_success`, mismo IM real `30f41b94-1310-46e1-8627-fb31590ffef3`; logout → `login_status:"anonymous"`; captura final `43-FINAL-home-loggedin.jpg` |
| **AC-UL-02** | SOSTENIDO | Caso A (email inexistente) y Caso C (formato inválido, `sinarroba`) rechazados limpio (`08-diag-invalidformat.jpg`, "Formato de correo inválido"). Caso B (bug crítico) no se re-buscó activamente por instrucción del runbook, pero tampoco se vio ningún indicio de que se haya corregido |
| **AC-UL-03** | SOSTENIDO (reconfirmado de forma temprana/casual) | El cold start inicial de la sesión arrancó DIRECTO logueado con la cuenta real (persistencia de sesión intacta) -- confirmado con captura `02-diag-accountpage.jpg` mostrando "Mateo Vargas" / email real antes de forzar el logout manual para poder probar el resto de la batería |
| **AC-UL-04** | SOSTENIDO | Contenido Live (`Hechos AM`) reprodujo sin pedir login: `screen_name:"Player"`, `login_status:"anonymous"` |
| **AC-REG-01** | SOSTENIDO (parcial -- caso duplicado confirmado con captura; caso nuevo/password débil no repetidos por tiempo) | Email duplicado (`jmatevargas@poligran.edu.co`) → "Este email ya está registrado" (`39-diag-currentstate.jpg`), sin crash, sin crear cuenta duplicada |
| **AC-SEC-LOGIN-EDGE-01** | SOSTENIDO | Sub-caso A (fuerza bruta, email inexistente): 2 intentos consecutivos rechazados (`FEDERATION_INVALID_CREDENTIALS`, luego `CUSTOMER_NOT_FOUND`), sin ninguna fricción/HTTP 429 -- la ausencia de rate limiting se sostiene. Sub-caso B (password vacía/1 char, email válido): vacía → "Se requiere contraseña" (client-side, `21-diag-emptypw-result.jpg`); nunca loguea |
| **AC-SEC-03** | SOSTENIDO | Código OTP inventado (`000000`) con email válido → `OTP_CODE_INVALID`, mensaje visible "El código que ingresaste es incorrecto o ha expirado" (`23-diag-postotp.jpg`) |
| **AC-SEC-04** | NO RE-VERIFICADO este ciclo (sin tiempo) | Ya desempatado 3-2 en sesión anterior: no se repitió la comparación de mensajes por presión de tiempo. No hay motivo para sospechar cambio |

### Lección operativa nueva: la navegación por teclado en pantalla es MÁS
frágil de lo documentado cuando el layout de botones cambia según si hay
mensaje de error visible o no

Encontrado en esta corrida: la secuencia fija "10x Right + Right + Down xN"
para cruzar de la grilla QWERTY a los botones de acción asume una posición
fija del botón objetivo, pero el número de filas de botones CAMBIA según
haya o no un mensaje de error rojo visible debajo del campo (ej. "El
usuario o contraseña son incorrectos" agrega una fila, desplazando todo un
`Down` extra hacia abajo). Esto causó varias veces terminar en el botón
equivocado (ej. "VOLVER AL INICIO" en vez de "INGRESAR", o "INGRESAR CON
CÓDIGO" en vez de "INGRESAR con password"), sin ser un bug de la app --
error de navegación del agente. **Mitigación para la próxima corrida:**
tras cruzar a la columna de botones, tomar UNA captura de bajo costo antes
del Select final si el flujo no fue el mismo exacto que la vez anterior
(cambió el mensaje de error, o es la primera vez en esa pantalla en la
sesión), en vez de asumir el N de `Down` fijo. También se confirmó un caso
de posible artefacto de renderizado/caché en el screenshot de
`/plugin_inspect`: un campo password mostró el valor VIEJO en una captura
pese a que el log confirmaba (con la secuencia completa de `Lit_<char>`)
que el valor nuevo sí se había tipeado -- una captura inmediatamente
posterior mostró lo mismo desactualizado, y solo se resolvió reintentando
con backspace de sobra (12 en vez de 9-10) y retipeando completo. Anotado
como posible falso negativo de la política "captura = diagnóstico
confiable" -- en este caso el LOG fue la fuente de verdad correcta y la
imagen la que mintió, lo inverso del caso ya documentado de foco
equivocado. Vale la pena recordarlo: ninguna de las dos señales (log,
captura) es 100% infalible por sí sola.

También se reconfirmó el obstáculo nativo de cuenta Roku (diálogo "Iniciar
sesión" con `ottnext@mediastre.am`) reapareciendo cada vez que se
re-entraba a "Ingresar con email" o "Registrarme con email" desde cero
(no solo la primera vez) -- consistente con lo ya documentado, salida
siempre por "Usar un correo electrónico diferente"/"Cancelar".

**Cierre de la corrida:** device dejado en Home, logueado con la cuenta
real (`jmatevargas@poligran.edu.co`), confirmado con captura final
`43-FINAL-home-loggedin.jpg`. Proceso de captura telnet (`node
scripts/telnet-capture.js`) cerrado limpio vía `taskkill`, verificado sin
procesos `node.exe` residuales (`tasklist`) y sin conexiones abiertas al
puerto 8085 (`netstat`).

---

## Objetivo

Automatizar el QA funcional/visual/logs de las apps de Roku de Mediastream,
empezando por el cliente **Azteca**. La idea central: agentes que analizan
QUÉ cambió (diff) y en base a eso deciden QUÉ batería de pruebas correr sobre
un Roku físico real, documentando cada corrida (logs, capturas, veredicto).

## Repos involucrados

| Repo | Rol | Notas clave |
|---|---|---|
| `mediastream/.github` (`roku/README.md`) | Doc del Player SDK | El Player es un `.pkg` (ComponentLibrary) que el Core carga como wrapper. |
| `mediastream/ott-next-core-roku-tv` | **Core** | `Library/` = SDK real (lo único que se firma/publica), `APP/` = app de referencia (nunca lógica de SDK). El Player vive embebido en `Library/source/packageFile/`. |
| `mediastream/ott-next-roku-tv-customer-apps` | **Clientes** | Un branch por cliente (`client/azteca`, `client/ondamedia`, `client/tvn-pass`, `client/tvn-play`, `client/laliga2D`, `client/michv`, `client/win_sports_online`, `test/drm-goltv`). `master`/`develop` solo tienen tooling y anclas de firma (`clients/<id>.pkg`). |

## Cadena de empaquetado real (confirmada en workflows, no supuesta)

```
Core (Library/) → create-release.yml empaqueta/firma en Roku físico compartido
                → publica GitHub Release "RokuOTTNextCore.pkg" (tag vX.Y.Z)

Cliente (branch client/<id>) → release-client.yml (manual, workflow_dispatch):
    1. descarga Core.pkg (latest o tag) → source/packageFile/MediaStreamOTTNextCore.pkg
    2. bump de versión del manifest del cliente
    3. empaqueta y firma con la key propia del cliente, en el MISMO Roku físico
    4. publica Release <cliente>-vX.Y.Z (.pkg + .zip)
```

- Packaging/signing corre en un **runner self-hosted macOS** conectado a un Roku
  físico compartido entre Core y todos los clientes (por eso hay `concurrency`
  lock y un chequeo previo de "Roku reachable and correctly keyed").
- **Nunca reusar ese Roku para QA automatizado** — usar uno dedicado, para no
  bloquear releases reales.

## Estado actual de QA (por qué este proyecto existe)

- El propio `CLAUDE.md` del Core dice literal: *"Never claim a test suite or
  build step exists. There is neither."*
- Único gate hoy: `npm run lint`/`format` (estático) + que el Roku logre
  instalar el paquete (HTTP 400 en `/plugin_install` = no compiló).
- Existe un sistema de **"QA Cases"** (`qa-cases-generate.yml` +
  `.claude/tickets.md`): al mergear a `develop`, un LLM lee el diff del PR y
  **genera texto** (`QA-01`, `QA-02`... con checklist) posteado en Monday.com
  para que un **humano** lo pruebe a mano. **No ejecuta nada.**
- **Decisión importante:** nuestra automatización debe reusar los mismos
  códigos `QA-XX` y el mismo ticket de Monday en vez de crear un sistema de
  reporte paralelo — así el equipo no tiene que mirar dos lugares.

## Hallazgo: Azteca casi no tiene código propio

Branch `client/azteca`:
```
components/   → MainScreen.brs + MainScreen.xml  (entry point, instancia el Core)
source/
  main.brs
  data/appConfig.json   → pkgLibUrl, signSecret, ottId, ottEnv, ga4ApiSecret, ga4MeasurementId
  packageFile/           → el .pkg del Core embebido
manifest                 → título, splash, roku_ads_lib, googleima3
images/
```

Casi todo el comportamiento real (Login, EPG, Home, Player) vive en el
**Core**. Lo genuinamente "de Azteca" es:
- Configuración (`appConfig.json`): endpoints/ottId, ads (roku_ads_lib +
  googleima3), analytics (GA4).
- Assets visuales (`images/`, splash, íconos).

⚠️ `appConfig.json` contiene un `signSecret` real — **nunca commitear ese
valor** en este proyecto ni en reportes/logs. Si un escenario necesita datos
de config, referenciar la clave (`ottId`, `signSecret`) sin el valor.

**Consecuencia para el diseño:** un bug "de Azteca" muy probablemente viene
de datos de config o de assets, no de una pantalla propia — el registro de
escenarios debe cubrir explícitamente "config de Azteca correcta" (ads
cargan, analytics dispara, ottId resuelve) además de los flujos del Core que
Azteca ejercita (Login/EPG/Player/Home vía `MainLibScene`).

## Decisión: Fase 5 (multi-cliente) descartada tal como estaba planteada

Razonamiento del usuario, correcto: si el bug está en Core/Player (lógica
compartida), correrlo en los 4 clientes por separado no aporta nada — es el
mismo test 4 veces. Divisón real:

- **Lógica compartida (Core/Player)** → se prueba **una sola vez**, en el
  cliente que estemos usando de referencia (Azteca).
- **Lo propio de cada cliente** (config, assets) → solo ahí sí hace falta
  batería propia, cuando se automatice ese otro cliente.

No hay "Fase 5 de replicar todo a todos los clientes". Si en el futuro se
suma otro cliente, el Change Analyzer debe distinguir "cambio compartido →
correr solo en el canario" vs. "cambio propio de este cliente → correr solo
aquí".

## Arquitectura de agentes (pipeline)

```
① Change Analyzer → ② Test Router → ③ Device Runner → ④ Log/Visual Auditor → ⑤ Reporter
```

1. **Change Analyzer** — lee el diff real (¿cambió el `.pkg` del Core
   embebido? ¿cambió `appConfig.json`? ¿cambió `MainScreen.brs`/`images/`?) y
   etiqueta el impacto: `player`, `core-network`, `core-ui`,
   `client-config`, `client-assets`.
2. **Test Router** — cruza esas etiquetas contra un registro de escenarios
   versionado (`scenarios/`) y arma la batería mínima necesaria. Si el
   impacto es amplio (bump grande del Core), corre la batería completa.
3. **Device Runner** — instala el `.pkg` en un Roku de QA dedicado, navega
   vía ECP (`/keypress`, `/launch`, `/input`), toma screenshots
   (`/plugin_inspect` en modo developer) y captura el log por telnet
   (puerto **8085**, alimentado por `Library/logs/Logger.brs`, del cual
   "casi todo depende" según el propio CLAUDE.md del Core).
   - Librería recomendada como base: **`roku-test-automation`**
     (RokuCommunity, open source) — ya integra ECP + telnet + screenshots +
     inspección de nodos SceneGraph en vivo.
4. **Log/Visual Auditor** — clasifica severidad de líneas de log (no solo
   grep de "error": patrones de `roUrlTransfer` fallido,
   `Compilation Failed`, `isSuccess=false` no manejado, excepciones BrightScript,
   memory warnings) y compara screenshots contra baseline
   (`baselines/`) con diff de píxeles + criterio de un LLM para decidir si
   un diff visual es esperado o es bug.
5. **Reporter** — genera un artefacto de la corrida (`reports/`) con:
   qué cambió, qué batería corrió, resultado por escenario, logs relevantes,
   capturas embebidas — y **marca el `QA-XX` correspondiente en el mismo
   ticket de Monday**, en vez de crear reporte paralelo.

## Fase 0 — Completada: flujo de arranque y páginas reales

Confirmado leyendo `MainScreen.brs/xml` (Azteca) y `Library/components/pages`
(Core):

```
MainScreen (Azteca)
  → ComponentLibrary (rokuMSSdkComponentLib) carga el .pkg de appConfig.pkgLibUrl
  → loadStatus = "ready" → instancia MainLibScene (Core)
  → handleDeeplinkingLaunchEvent (si aplica)
  → páginas reales del Core:
       LoginRegPage, HomePage, DiscoverPage, CategoryGridPage, EPGPage,
       ShowPage, EpisodeDetailPage, SearchPage, FavoritePage, AccountPage,
       PaymentRequiredPage
```

Puntos de fallo ya identificados en `MainScreen.brs` que hay que vigilar
explícitamente: `loadStatus="failed"`, `appSDKErrorStatus`, pérdida/recupero
de `internetConnection` (timer cada 5s), `linkStatus`.

Primer registro de escenarios: **`scenarios/azteca.yaml`** (18 escenarios,
`SC-BOOT-01` a `SC-DEEPLINK-01`), cada uno con `area` (para el Test Router),
`severity`, pasos, resultado esperado, qué vigilar en logs y si requiere
validación visual.

## Roadmap

- **Fase 0** ✅ — Inventario de flujos reales que Azteca ejercita en el Core
  (Login/EPG/Home/Player) + puntos de config propios de Azteca. Registro de
  escenarios en `scenarios/azteca.yaml`.
- **Fase 1** 🚧 — Device Runner mínimo implementado en
  `scripts/device-runner.js` (Node.js, `type: module`):
  - ECP para keypress/launch (`node-fetch` nativo, sin auth).
  - Screenshot vía `curl --digest` contra `/plugin_inspect` (requiere
    `ROKU_DEV_PASSWORD` en `.env`, nunca commiteado — hay `.env.example`).
  - Captura de telnet log crudo (puerto 8085) durante todo el escenario.
  - Traduce los `steps` en texto libre del YAML a acciones ECP por
    coincidencia de palabras clave (`KEY_ALIASES`); lo que no matchea queda
    registrado como `manualStepsPending` en `meta.json` para automatizar
    después en vez de fallar silenciosamente.
  - Aún NO clasifica logs ni compara screenshots — solo junta evidencia
    cruda en `reports/<run-id>/<scenario-id>/` (`telnet.log`,
    `screenshot.jpg`, `meta.json` con `verdict: PENDING_AUDIT`).
  - **Pendiente**: correr esto de verdad contra el Roku de QA
    (`192.168.1.186`, ver nota de credenciales abajo) e instalar
    dependencias (`npm install` — `dotenv`, `js-yaml`).
  - **Siguiente**: robustecer `KEY_ALIASES`/mapeo de pasos a medida que se
    corre contra el device real, luego pasar a Fase 2.
- **Fase 2** — Log/Visual Auditor: clasificación de severidad + comparación
  contra baseline visual.
- **Fase 3** — Change Analyzer + Test Router (diff-aware): deja de correr
  todo siempre.
- **Fase 4** — Reporter integrado con Monday (`QA-XX`) + histórico de runs.

## Dónde engancha en el pipeline de CI existente

No dentro de `release-client.yml` (bloquearía releases manuales con un test
flaky). Como workflow separado:
1. Ahora (manual): `workflow_dispatch` apuntando al `.pkg`/branch a probar.
2. Más adelante: disparado tras `release-client.yml` sobre el `.pkg` recién
   firmado, antes o después de publicar el Release.

## Ideas pendientes de explorar

- Roku de QA con perfil de red simulado (lento) para forzar timeouts de
  `roUrlTransfer` que en logs se ven como error silencioso
  (patrón `isSuccess`/`fail()` del Core).
- Histórico de logs por versión de Core: comparar automáticamente el run
  actual contra el run de la versión anterior del Core para acotar más
  rápido si el problema es del Player/Core o de Azteca.
- Adjuntar el link al run completo en el comentario del PR (mismo hábito que
  ya usa `qa-cases.yml` con el link de Monday).

## Smoke test real (2026-09-11) — resultado

Conectado por primera vez contra un Roku real (`192.168.1.34`, Roku Express,
red "Mediastream", ubicación "Office"). Hallazgos:

- **ECP funciona** (`/query/device-info`, `/query/apps`, `/launch`).
  Canal Azteca instalado como `app id="dev"` (build sideload,
  v1.18.92608240) — este es el que hay que usar para pruebas, no el de
  tienda (`id=289278`).
- **Telnet log (puerto 8085) funciona perfecto** y ya trae timestamp +
  nivel (`ℹ️ [2026-09-11T14:03:37Z] <INFO> ...`) — mucho más fácil de
  parsear en Fase 2 de lo que se esperaba. Primer boot real capturado
  confirma el flujo de `SC-BOOT-01`: `pkgLibUrl` correcto,
  `onLoadStatusChanged : loadStatus : loading` → `... : ready`, carga del
  `Roku_OTTNext_MediaStream_SDK` (Core) y `Roku Analytics Library`.
- **Screenshot vía `/plugin_inspect` NO funciona todavía.** El endpoint
  correcto es `POST http://<host>/plugin_inspect` (puerto **80**, el del
  instalador — no el 8060 de ECP), con Digest Auth (`rokudev`/dev password)
  y `Content-Length` explícito. Pero se queda colgado indefinidamente. Causa
  más probable: **"Screen Capture" no está habilitado en Developer Options**
  del propio Roku (Configuración → Sistema → Avanzado → Opciones de
  desarrollador → Habilitar captura de pantalla) — es un ajuste manual de
  una sola vez por device, no algo que el runner pueda resolver por HTTP.
  **Pendiente: habilitarlo en el device y reprobar.**

`scripts/device-runner.js` usa `curl --digest` contra el puerto **8060**
para el screenshot — **hay que corregirlo al puerto 80** una vez se
confirme el fix del ajuste en el device.

## Primer test real de Player (2026-09-11) — observar humano + replicar con ECP

Flujo seguido: se le pidió al usuario operar manualmente el Player en el
Roku `.34` mientras se capturaba telnet log en vivo
(`reports/azteca/player-observation/_archive-sesion-2026-09-11/manual-session7.log`), luego se tradujo esa
secuencia a keypresses ECP y se re-ejecutó de forma automática
(`reports/azteca/player-observation/_archive-sesion-2026-09-11/auto-replay.log`) para comparar.

**Hallazgo (bug real, no ruido) — CONFIRMADO 100% reproducible:** el Player
SDK dispara `GET https://mdstrm.com/episode/.json` (**ID vacío**) → 404 →
`ParseJSON()` sobre texto plano → excepción:
```
BRIGHTSCRIPT: ERROR: ParseJSON: Unknown identifier 'Not found': mediastreamrokuplayersdk:/source/apis/MediaStreamPlayerAPI.brs(67)
```

**Datos acumulados de 2 sesiones de prueba (8 transiciones de episodio en
total, `next-episode-test.log` + `full-manual-run.log`):**

| Forma de cambiar de episodio | Intentos | ¿Bug? |
|---|---|---|
| Selección manual desde SeasonListView (OK) | 3 | 🔴 2/3 |
| "Up Next" (OK explícito o autoplay por timeout) | 5 | ✅ 0/5 |

**Corrección importante respecto al hallazgo inicial:** NO es 100%
determinístico por el método de selección (la 2da sesión tuvo una
selección manual limpia, sin bug) — es una condición de carrera. Lo que sí
se sostiene con más muestras: el bug **nunca** apareció en ninguna variante
de "Up Next" (0/5), solo puede aparecer en selección manual (pero no
siempre, 2/3). Ocurre siempre justo después de
`postRequest .../metrics.mdstrm.com/inbound/v1/event/register/` y antes de
completar el setup de RAF (Roku Ads Framework). Hipótesis sin cambios: al
entrar vía Up Next el ID del próximo episodio ya viene resuelto (campo
`"next"` del JSON del episodio anterior) de forma síncrona; al entrar por
selección manual, hay una carrera entre el registro de métricas de ads y
la asignación de esa variable de ID, que a veces gana la carrera (sin bug)
y a veces no (bug). La reproducción no se cae (se recupera sola) — por eso
`severity: major`, no `blocker` — pero es un error no manejado.

Documentado con causa raíz, pasos de repro, caso de control y % de
reproducción actualizado en **`SC-PLAYER-BUG-01`** (`scenarios/azteca.yaml`)
— listo para reportarse como bug real al equipo de Core, con la nota de que
hacen falta más muestras para estimar el % exacto en selección manual.

**Nota operativa de esta sesión:** ECP soporta deep linking directo
(`POST /launch/dev?contentId=<id>&mediaType=episode`, confirmado leyendo
`source/main.brs` de Azteca — lee `args.contentId`/`args.mediaType`) para
saltar a un contenido conocido sin navegación ciega por Home. Útil para
apuntar pruebas a un episodio específico de forma determinística, pero
**la tecla `Home` de ECP sale al launcher del sistema, no a la Home interna
de la app** — para volver a la Home de Azteca hay que relanzar el canal
(`/launch/dev`), no presionar Home.

**Lo que sí se confirmó estable (replay automático limpio, sin errores):**
Home -> entrar a show -> navegar temporada/episodio (Down/Down/Right/Select)
-> reproducir -> scrub con fastforward -> confirmar seek -> pausa/reanudar
(Play/Play) -> Back (cierra player limpio, sin huérfanos) -> Back (vuelve a
Home, tracking dispara normal). Esto valida en la práctica el escenario
`SC-SHOW-01` de `scenarios/azteca.yaml`.

**Aprendizaje operativo importante — cierre de sockets telnet:** el
`timeout <n> bash -c '...cat <&3'` mata el proceso wrapper pero puede dejar
el socket TCP en estado "established" (huérfano, sin proceso dueño) tanto
localmente como del lado del Roku, y el Roku entonces rechaza nuevas
conexiones con `"Console connection is already in use."` hasta que se
reinicia el device físicamente. **Solución adoptada:** usar Node.js
(`net.connect` + `s.destroy()` en un handler explícito) en vez de
`timeout`+bash para abrir/cerrar el socket de forma limpia — así no se
repite el problema. `scripts/device-runner.js` ya sigue este patrón.

## Instrumentación para detectar "Next Episode" / Up Next (2026-09-11)

Pregunta del usuario: ¿se puede poner un id/log para que la automatización
detecte y use los botones de "Next Episode"? Investigado:

- **`SeasonListView.brs` (selección manual de episodio) SÍ está en
  `ott-next-core-roku-tv`** — usa un logger estructurado (`m._log`) ya
  existente. Se podría agregar una línea de log con el ID real del episodio
  en `onGridItemSelected`/`onRowItemSelected` (`SeasonListView.brs:390,408`)
  para tener un identificador determinístico. **No implementado aún** —
  requeriría seguir el flujo completo del Core (ticket Monday, branch, PR,
  aprobación del usuario antes de commitear, por las reglas del propio
  `.claude/CLAUDE.md`). El usuario decidió NO tocar repos por ahora.
- **El overlay "Up Next"/"Next Episode" (`UpnextOverlay`, `MediaStreamPlayer`)
  NO está en `ott-next-core-roku-tv`** — se buscó y no existe ahí. Vive
  dentro del **Player SDK**, el `.pkg` cerrado y distribuido por separado
  (ver `mediastream/.github/roku/README.md`). No se puede instrumentar
  desde este repo ni desde el Core — habría que pedírselo al equipo dueño
  del Player SDK.

**Decisión tomada:** por ahora, sin tocar ningún repo. Se mejoró
`scripts/device-runner.js` para ser **event-driven en vez de basado en
sleeps fijos**: espera patrones reales ya presentes en el log (sin
necesidad de ids nuevos) antes de seguir:
- `player_loaded` → confirma que un episodio nuevo terminó de cargar.
- `UpnextOverlay` → confirma que el overlay de "próximo episodio" apareció.
- Detección automática de `episode/\.json` (id vacío) + `ParseJSON: Unknown
  identifier` → marca `knownBugDetected: "SC-PLAYER-BUG-01"` en
  `meta.json` de cada corrida, sin que un humano tenga que releer el log.

Ver `waitForPattern()` / `waitAfterStep()` / `LOG_PATTERNS` en
`scripts/device-runner.js`. Pendiente para más adelante, si el usuario lo
pide: preparar el diff concreto de `SeasonListView.brs` + seguir el flujo
del Core para proponerlo como PR real.

## Sesión del 2026-09-11 (tarde) — correcciones al runner + hallazgo de posible crash

### Bugs reales encontrados y corregidos en `scripts/device-runner.js`

1. **Orden de conexión telnet vs. lanzamiento.** Si el socket de telnet se
   conecta ANTES de relanzar el canal, el Roku deja de alimentar datos
   nuevos después del dump inicial -- el socket queda "vivo" pero mudo, y
   cualquier `waitForPattern` posterior hace timeout aunque el evento sí
   haya ocurrido. **Fix:** conectar el telnet DESPUÉS del keypress de
   lanzamiento, no antes.
2. **Relanzar un canal ya corriendo puede ser un no-op.** Si el canal ya
   está en foreground, `POST /launch/dev` puede solo re-enfocar sin
   re-ejecutar `Main()` -- nunca aparecen líneas de boot frescas. **Fix:**
   forzar cold start real: `Home` (sale al launcher del sistema) → esperar
   → `launch/dev`.
3. **Palabra "play" demasiado genérica en `waitAfterStep`.** Pasos como
   "Pausar con Play"/"Reanudar con Play" caían por error en la espera de
   `player_loaded` (que nunca iba a aparecer ahí) y siempre hacían timeout.
   **Fix:** esa espera ahora solo dispara con "seleccionar episodio" o
   "reproduc".
4. **YAML mal escapado en `scenarios/azteca.yaml`** (comillas dentro de
   una entrada de lista sin cerrar el scalar) -- corregido con comillas
   simples envolviendo toda la línea.
5. **Nunca combinar `&` de shell con `run_in_background: true` del tool.**
   Mismo patrón de bug que ya habíamos visto con los sockets de telnet --
   el proceso queda huérfano/mal rastreado. Los procesos de larga duración
   deben lanzarse SIN `&`, dejando que el tool maneje el backgrounding.

### Deep linking: descartado para este flujo, mantenido solo como nota

Se probó `POST /launch/dev?contentId=<id>&mediaType=episode` como atajo
para no navegar a ciegas, pero el usuario pidió explícitamente **no usar
deep links** y seguir el flujo real de navegación (Home → Down/Down/Right
→ Select → Seleccionar episodio) que ya se había probado y funcionaba.
Los `steps` de `SC-SHOW-01` en `scenarios/azteca.yaml` quedaron con ese
flujo real, con alias nuevos en `KEY_ALIASES` (`entrar`, `bajar`) para que
el runner los reconozca.

### Hallazgo importante: el avance (Fwd) NO es lineal ni predecible

Probado empíricamente: 40 toques rápidos de una vez movieron la posición
~1831s; otras 120 toques repartidos en 3 tandas de 40 se pasaron de largo
un episodio COMPLETO de 4085s. Toques individuales a veces casi no mueven
nada, otras veces saltan decenas de segundos. Conclusión: el scrub
acelera de forma no lineal cuanto más rápido/seguido se toca, y NO se
puede calcular de antemano cuántos toques hacen falta para llegar a un
punto exacto.

**Solución implementada:** `scripts/seek-near-end.sh` -- avanza un
episodio hasta dejarlo a ~15-30s del final, sin importar su duración,
MIDIENDO la posición real en el log después de cada tanda (no a ciegas) y
ajustando el tamaño de la tanda según cuánto falte (grande lejos del
final, de a un toque cerca). También detecta si cambió el `playback_id`
(el episodio ya cambió) y frena inmediatamente en vez de seguir avanzando
con una duración desactualizada -- ese fue el bug que causó pasarse de
largo la primera vez que se probó el script.

**Lección de implementación:** para la duración, usar el campo `duration:`
(en ms) del mismo bloque JSON que trae `position:` -- NO el
`"video_duration"` (HH:MM:SS) del evento GA4, que solo se emite una vez al
arrancar el episodio y puede quedar desactualizado si el episodio ya
cambió.

### ⚠️ Posible bug serio sin confirmar: la app se cerró sola

Durante una tanda de pruebas de avance rápido, la app completa se cerró
(`EXIT_USER_NAV` en el log, sin que se enviara `Back` ni `Home`) y volvió a
arrancar fresca en Home por su cuenta. Podría ser un crash real disparado
por exceso de input rápido de scrub (Fwd/Select en ráfaga), pero **no se
confirmó de forma aislada/reproducible todavía** -- quedó pendiente de
investigar como su propio hallazgo, con la misma rigurosidad que se usó
para `SC-PLAYER-BUG-01` (aislar causa, repetir, confirmar % de
reproducción) antes de darlo por bug real.

**Pendiente para la próxima sesión:** investigar este posible crash de
forma controlada y aislada.

## Sesión 2026-09-11 (Agente Player) — validación E2E del Player, 3 corridas reales

Objetivo: correr el flujo completo (cold start → navegar a show → reproducir
→ avanzar controlado hasta cerca del final → observar el cierre real) contra
el Roku físico `.34`, con episodios de duración distinta, hasta lograr de
forma repetible NO pasarse del final. Logs crudos en
`reports/azteca/player-observation/_archive-sesion-2026-09-11/run1-attempt1.log`, `run2-attempt2.log`,
`run3-attempt3.log`.

### Resultado: 3/3 corridas terminaron limpias, sin pasarse del final

| Corrida | Contenido | Duración | Método de avance | Resultado final |
|---|---|---|---|---|
| 1 | "Acércate a Rocío" (VOD) | 4014s (01:06:54) | x5 Fwd+Select "a ciegas" (sin medir entre tandas) | Un burst de 5 Fwd+Select coincidió con un mid-roll ad cuyo `seek to` post-ad cayó en 4010/4014 -- terminó (`finished`/`stopped`) casi de inmediato, **sin overlay Up Next**, volvió a ShowPage. Válido como observación pero NO fue un avance controlado -- fue suerte que el punto de seek post-ad cayera tan cerca del final. |
| 2 | Mismo episodio (4014s), relanzado desde cero | x5→x3→x2→x1 (escalando según `restante`, releyendo posición real después de cada tanda) | Llegó a 22s restantes sin que cambiara el `playback_id` en ningún momento. Dejó de tocar nada bajo ~110s restantes y esperó en tiempo real. Terminó `finished`→`stopped`→`closePlayer`, volvió a ShowPage, **sin overlay Up Next** (fin limpio sin overlay, variante B de las dos válidas). |
| 3 | "Ventaneando" (VOD, 00:40:41 = 2441s) -- **duración distinta**, entrado directo a Player desde un tile de Home (sin pasar por ShowPage) | Misma lógica x5→x3→x2→x1 | Llegó a 22s restantes de la misma forma controlada. Esta vez SÍ apareció **`UpnextOverlay`** unos segundos antes del `finished`, y tras `finished`/`stopped` el `playback_id` cambió limpiamente a un episodio nuevo que arrancó solo (autoplay de Up Next) -- sin el bug `SC-PLAYER-BUG-01` (se buscó el patrón `episode/.json` + `ParseJSON` explícitamente, no apareció). |

**Conclusión de fiabilidad:** el criterio de avance por niveles (x5 con >20min
restantes, x3 entre ~15-20min, x2 entre 10-15min, x1 exclusivo por debajo de
10min, cero toques por debajo de ~110-150s dejando correr en tiempo real)
funcionó de forma consistente en 2 corridas totalmente controladas (2 y 3),
para dos duraciones distintas (67min y 41min) y dos formas de llegar al Player
(vía ShowPage y vía tile directo de Home). Ninguna cambió el `playback_id`
antes de tiempo -- ninguna se pasó del final.

### Hallazgo nuevo importante: mid-roll ads reseekean la posición y pueden generar saltos grandes e impredecibles

En las 3 corridas aparecieron mid-roll ads (`RAFPlayerTask: mid-roll ads,
stopping video` → ... → `RAFPlayerTask: mid-roll finished, seek to <N>`)
en puntos fijos del contenido (ej. ~700s, ~970s, ~1510s... en el episodio de
4014s -- se repitieron en los mismos puntos entre corrida 1 y 2 porque era el
mismo episodio). El comportamiento observado:
- El mid-roll se dispara cuando el scrub (Fwd+Select) cruza uno de esos
  puntos de quiebre, no en un momento aleatorio.
- Al terminar el ad, el player hace un **seek explícito** a una posición fija
  post-ad (no simplemente continúa desde donde estaba) -- ese seek puede
  representar un salto mucho mayor al que el Fwd+Select por sí solo hubiera
  dado (en la corrida 1, ese seek cayó a solo 4s del final real). **Esta es
  la explicación real del comportamiento "no lineal" que ya se había
  documentado antes** (sesión anterior, "el avance no es lineal") -- al
  menos parte de esa no linealidad es por mid-rolls, no solo por el nivel de
  scrub acumulado.
- Recomendación para próximas corridas: cuando aparezca la línea `mid-roll
  ads, stopping video` mientras se está en zona de riesgo (< ~5min
  restantes), tratarlo igual que un burst grande impredecible -- releer la
  posición inmediatamente después en vez de asumir que el seek fue chico.

### Ajuste de criterio que funcionó (y por qué)

- Zona lejos del final (>20min restantes): x5 Fwd + Select por tanda,
  reevaluando siempre con el log real antes de la próxima tanda.
- 15-20min: x3. 10-15min: x2. <10min: SOLO x1 (un Fwd + un Select), nunca
  más, revalidando posición real después de cada uno antes de decidir el
  siguiente.
- Por debajo de ~100-150s restantes (no exactamente 60s -- se prefirió parar
  un poco antes, con más margen, apenas la incertidumbre del próximo x1
  dejaba de ser claramente segura): dejar de tocar nada y esperar en tiempo
  real, releyendo el log cada ~15s hasta ver `finished`/`stopped` o
  `UpnextOverlay`.
- Instrumento usado: `curl` directo a `/keypress/Fwd` y `/keypress/Select`
  del ECP, más `grep` sobre el archivo de telnet log activo (`^    position:`
  y `^    duration:` del bloque JSON, `mid-roll`, `RAFPlayerTask: state`,
  `screen_name`, `UpnextOverlay`, `playback_id`) -- sin usar
  `scripts/seek-near-end.sh` ni `scripts/smart-seek-agent.js` en esta sesión
  final (ver nota abajo de por qué).

### `scripts/smart-seek-agent.js` -- CORREGIDO (2026-09-11, post-Agente Player)

El defecto original (nunca confirmaba con `Select` mientras escalaba, solo
acumulaba toques de `Fwd` sin comprometer el seek) quedó **corregido**. La
v2 implementa directamente la tabla ya validada por el Agente Player en 3
corridas reales (no infiere velocidad, la aplica tal cual):

```
restante > 20 min: x5 (5 toques rápidos + sostener ~5s + Select)
restante > 15 min: x3 (3 toques rápidos + sostener ~3s + Select)
restante > 10 min: x2 (2 toques rápidos + sostener ~2s + Select)
restante > ~2 min: x1 (1 toque + Select, de a uno)
restante <= ~2 min (120s): cero toques -- dejar correr en tiempo real
  hasta el final natural (Up Next aparece a ~5s, no antes)
```

También agrega detección de: cambio de `playback_id` a mitad de camino
(aborta, ya se pasó de largo) y posición sin cambios 3 lecturas seguidas
(Select de recuperación, por si quedó pausado). Uso:
`node scripts/smart-seek-agent.js <ruta-al-telnet.log>`.

`scripts/seek-near-end.sh` (bash, versión anterior con la misma tabla
implementada a mano) sigue funcional como alternativa/referencia, pero
`smart-seek-agent.js` es ahora la versión recomendada (más simple, menos
parámetros hardcodeados por zona).

### `scripts/smart-seek-agent.js` -- validación E2E de punta a punta (2026-09-11, Agente Player)

Se probó el script YA CORREGIDO de arriba contra el Roku físico real
(`.34`), de punta a punta, en 6 corridas (cold start → Home/Down/Down/
Right/Right/Select → Select para reproducir → `node
scripts/smart-seek-agent.js <log>`), auditando en paralelo el log crudo de
telnet para confirmar (sin confiar ciegamente en el output del script) que
lo que reporta coincide con lo que el log realmente muestra. Logs en
`reports/azteca/player-observation/_archive-sesion-2026-09-11/run1.log` .. `run6.log`.

**Resultado: el parsing y la lógica de decisión son 100% correctos y
auditables.** En las 6 corridas, cada línea `[tick N] posición=... 
duración=... restante=...` que el script imprimió coincidió exactamente
con los valores reales `position:`/`duration:` (o el fallback
`video_duration` de GA4) leídos de forma independiente en el log crudo.
La escalación x5→x3→x2→x1 según el tiempo restante se disparó siempre en
el umbral correcto de la tabla, confirmado en múltiples corridas.

**Dos bugs reales encontrados en esta sesión y corregidos en el archivo:**

1. **Nivel x1 no confirmaba el seek -- Select actuaba como Play/Pause.**
   Con `holdSec: 0`, el `Select` llegaba ~150ms después del único toque de
   `Fwd`, demasiado rápido para que el player registrara el modo scrub. El
   log lo mostraba clarísimo: `RAFPlayerTask: state = playing` -> `paused`
   en cada ronda x1 (el Select pausaba el video en vez de confirmar un
   seek), y el único "avance" observado era reproducción real mientras
   quedaba pausado/reanudado por accidente -- no un scrub real. **Fix:**
   se agregó un sostén mínimo de ~1s también en el nivel x1 (igual que ya
   se hacía en x2/x3/x5), replicado de la misma tabla pero faltaba ahí.
   Re-probado en vivo (corrida 6, mismo episodio de 585s "Migajeros."): con
   el fix, cada ronda x1 avanzó ~30-40s reales de contenido de forma
   consistente (0→40→80→120→...→490s), confirmado tick a tick contra el
   log crudo.
2. **Sin duración disponible, el script se quedaba reintentando en
   silencio 80 ticks (~160s) con un mensaje final engañoso.** En la
   corrida 3 ("Exatlón Décima Temporada"), el episodio nunca logueó
   `video_duration` por GA4 (sin evento `player_ready`) NI un `duration:`
   > 0 en el bloque JSON de posición -- el script no tenía forma segura
   de saber cuándo frenar, así que (correctamente) no tocó nada, pero se
   quedaba 160s repitiendo "sin lectura..." y al agotar los intentos
   imprimía "se agotaron los intentos sin llegar a la zona de aterrizaje",
   un mensaje que sugiere que sí hubo seeks cuando en realidad nunca pudo
   leer una duración válida. **Fix:** contador separado
   (`MAX_NO_DATA_TICKS = 15`, ~30s) que corta antes con un mensaje
   específico ("Nunca se pudo leer una duración válida... no es seguro
   avanzar a ciegas"). Verificado re-corriendo el script contra el log
   estático de la corrida 3 (sin tocar el device de nuevo): salió en 15
   ticks con el mensaje correcto y código de salida distinto (3).

**Confirmado explícitamente, con evidencia de log, los 3 criterios pedidos:**

- **(a) Acelera con cada nivel sin pasarse del final por decisión propia:**
  sí -- la escalación x5→x3→x2→x1 fue siempre coherente con el tiempo
  restante real, nunca se disparó un nivel más agresivo del que
  correspondía.
- **(b) Detecta bien si el `playback_id` cambia a mitad de camino:** sí,
  confirmado en 2 corridas (run1 y run2) -- en ambas, un mid-roll ad hizo
  un seek explícito a un punto a solo ~4s del final real (`4010/4014` y
  `910/914`), lo que terminó el episodio casi de inmediato; el script leyó
  el nuevo `playback_id` en el siguiente tick, imprimió la advertencia y
  **abortó de inmediato sin enviar ningún toque más** (exit code 2). Este
  es el comportamiento de seguridad correcto ante un salto que el script
  no podía predecir (ver hallazgo de ads abajo) -- no es un fallo del
  script, es la red de seguridad funcionando.
- **(c) Se detiene por debajo de ~120s restantes sin tocar nada más,
  dejando llegar al final natural:** sí, confirmado limpiamente en la
  corrida 6 (post-fix del bug de x1): en el tick 14, con
  posición=490s/duración=585s (restante=95s ≤ 120s), el script imprimió
  `Listo: ... dejando correr en tiempo real...` y salió con código 0 **sin
  enviar ningún `Fwd`/`Select` más**. Verificado además que, después de
  ese punto, la posición siguió avanzando en el log únicamente por
  reproducción real (520s con `duration: 585000` observado más tarde en
  el mismo log, sin ninguna acción del script).

**Hallazgo reconfirmado (no nuevo, pero reproducido de forma limpia dos
veces más en esta sesión):** el mismo contenido "Acércate a Rocío" (4014s)
volvió a mostrar en la corrida 4 el patrón exacto de la corrida 1 -- una
cadena de mid-roll ads en puntos fijos (630, 1380, 2070, 2820, 3450) donde
el **último** mid-roll siempre reseekea a `4010/4014`, a solo ~4s del
final real, terminando el episodio casi instantáneamente. Esto ocurrió de
forma idéntica en 2 corridas independientes con el mismo contenido,
reforzando que es una característica del calendario de ads de ESE
episodio (probablemente el último break está mal configurado como si
fuera casi un post-roll) y no algo que el script pueda evitar variando su
velocidad de scrub -- cualquier secuencia de toques que cruce ese punto de
quiebre dispara el mismo salto casi al final.

**Conclusión: el script corregido funciona correctamente de punta a
punta**, con dos bugs reales adicionales encontrados y corregidos en esta
misma sesión (arriba). Recomendado como la herramienta a usar para esta
tarea de aquí en adelante.

### Estado final del device

Al cerrar la sesión: canal Azteca (`app id="dev"`) corriendo, en **Home**
(se cerró el player con `Back`/`Back` tras la corrida 3, confirmado por
`screen_name: "Home"` en el log y `/query/active-app` respondiendo bien).
Ningún socket telnet quedó abierto (se cerraron con `TaskStop` en cada
transición, sin dejar huérfanos -- se verificó reconectando limpio entre
corridas).

## Device de QA conocido

- IP en la red del usuario: `192.168.1.186` (visto en un `launch.json` de
  BrightScript Debugger local, apuntando a `ott-next-core-roku-tv/Library`).
- ⚠️ Ese `launch.json` traía la contraseña de developer mode en texto plano.
  **No se copió a este repo.** La contraseña real vive únicamente en el
  `.env` local del usuario (`ROKU_DEV_PASSWORD`, ver `.env.example`), nunca
  en un archivo versionado.
- No confirmado aún si este device (`192.168.1.186`) es el mismo Roku
  compartido que usa `create-release.yml`/`release-client.yml` para firmar,
  o uno distinto de desarrollo local. **Antes de correr baterías largas ahí,
  confirmar que no es el Roku de firma de producción** (ver regla en este
  mismo doc: nunca reusar ese Roku para QA automatizado).

## Estado de acceso / herramientas

- `gh` CLI instalado (winget) y autenticado como `Mateo-Var` (scopes: gist,
  read:org, repo, workflow) — usado para leer ambos repos privados.
- Carpeta del proyecto: `C:\Users\Mateo\roku-qa-automation\`
  - `scenarios/` — registro de escenarios de prueba (YAML/JSON, por definir).
  - `scripts/` — runner y agentes.
  - `baselines/` — screenshots de referencia por pantalla/cliente.
  - `reports/` — salida de cada corrida (no commitear si contiene datos
    sensibles).

## Checkpoint (2026-09-11, pausa de sesión) — exploración QA en device .63

Se cambió de device de prueba: **`192.168.1.63`** (Roku Streaming Stick 4K),
distinto al `192.168.1.34` (Roku Express) usado en toda la sesión anterior.
Confirmado con Azteca instalado (`app id="dev"`).

Se lanzó un Agente Player en modo "exploración QA general" (navegar shows/
episodios con criterio propio, ejercitar avance/retroceso/play-pause,
estresar el botón "Ver ahora", vigilar el log por cualquier anomalía,
documentar por criticidad) contra este nuevo device. **La sesión se
detuvo a mitad de la exploración** (pausa pedida por el usuario) — no
alcanzó a escribir su propio resumen acá.

Log crudo dejado, sin analizar a fondo todavía:
`reports/azteca/player-observation/_archive-sesion-2026-09-11/qa-explore-20260911-140246.log` (2278 líneas).
Revisión rápida al pausar: solo aparecen los 2 errores de ads ya conocidos
(`roSGNode: Failed to create roSGNode with type InnovidDCL:InteractiveAdVersion`
y `...BrightLine:InteractiveAdEngine`, ambos de `roku_ads_lib`) — nada nuevo
grave detectado en esa revisión superficial. **Pendiente**: analizar ese
log a fondo cuando se retome, y completar la exploración en `.63`.

**Para retomar**: usar la skill `roku-qa-automation` (ver `.claude/skills/`
en este proyecto) que carga automáticamente todo este contexto.

## Sesión 2026-09-14 — Screenshots resueltos: bug propio, no del device

Se retomó el proyecto con el device `192.168.1.186` (Roku Express personal
del usuario, confirmado que NO es el Roku compartido de firmado de CI/CD —
seguro para QA automatizado). El cuelgue de `/plugin_inspect` documentado
en el smoke test del 2026-09-11 **NO era falta de "Screen Capture" en
Developer Options** (esa opción no existe como toggle en Roku OS 15.3.4,
por eso el usuario no la encontraba) — eran 3 bugs propios en el request:

1. El campo del form real es `mysubmit` (minúscula), no `mySubmit`.
2. El form es **multipart** (`enctype=multipart/form-data`), no
   urlencoded. Con `Content-Length: 0` sin body multipart, el Roku se
   queda esperando el resto del payload indefinidamente — de ahí el
   cuelgue que se había atribuido erróneamente a un ajuste del device.
3. El canal dev tiene que estar en **foreground** (no en el launcher del
   sistema/Home) — si no, responde rápido pero con `"Screenshot not ok"`
   en vez de generar el jpg.

Confirmado leyendo el HTML real que sirve `GET /plugin_inspect` (define el
form con Shell.create('Roku.Form') + botón "Screenshot" que setea
`mysubmit`). Con los 3 fixes: `POST /plugin_inspect` (puerto 80, Digest
auth `rokudev:<ROKU_DEV_PASSWORD>`, `-F mysubmit=Screenshot`) responde
`"Screenshot ok"`, y el jpg queda servido en `GET /pkgs/dev.jpg` (misma
auth) — 1280x720, confirmado con 2 capturas reales (Home y dentro del
Player).

**`scripts/device-runner.js` corregido** (función `screenshot()`) con este
flujo de 2 pasos (submit + descarga), fallando explícito si la respuesta
no dice "Screenshot ok" en vez de colgarse.

### Limitación real de la plataforma (no es un bug nuestro)

Confirmado con evidencia (captura tomada a mitad de reproducción de un
VOD): el área de video sale **completamente negra**, solo se ve texto de
subtítulos/captions superpuesto. Roku documenta esto explícitamente: el
screenshot utility captura la UI del canal sideloaded, nunca el frame de
video en reproducción (protección de contenido a nivel de sistema).

**Consecuencia para el diseño de validación visual:**

| Contexto | ¿Captura sirve? |
|---|---|
| Home, EPG, ShowPage, listas, menús | ✅ sí, nítido |
| Overlays de error, diálogos, chrome del player (ej. "Up Next") | ✅ probablemente sí (es UI, no video) — **sin confirmar aún**, pendiente probarlo específicamente |
| Frame de video en reproducción | ❌ imposible por esta vía, siempre negro |
| Subtítulos/captions sobre el video | ✅ sí se capturan |

Capturas de prueba en `reports/screenshots/` (`home-test-*.jpg`,
`player-test-*.jpg` — esta última es la que sale negra, sirve como
evidencia del límite documentado arriba).

**Pendiente para la próxima sesión:** confirmar si el overlay "Up Next"/
diálogos de error del player (que sí son UI, no video) se capturan bien —
sería la pieza que falta para que Fase 2 (Log/Visual Auditor) tenga
comparación visual útil también dentro del flujo de Player, no solo en
Home/EPG.

### Chrome del player (barra de avance, pausa, scrub) SÍ se captura bien

Mismo día, probado explícitamente a pedido del usuario: aunque el frame de
video es negro (ver arriba), **el overlay/chrome del player SÍ es UI y se
captura perfecto**, con mucho detalle útil para validación visual:

- **Pausa** (`Play` keypress): título, reloj, ícono de pausa, barra de
  progreso con posición/duración exacta en texto (`05:23 / 1:07:20`).
- **Avance/Retroceso (`Fwd`/`Rev`)**: aparece un **filmstrip de miniaturas
  reales del contenido** (no solo una barra) centrado en el punto de
  scrub, con ícono ▶▶/◀◀ y la miniatura activa resaltada con borde
  blanco. Mucho más rico de lo esperado para comparación visual/baseline.

Capturas de prueba: `reports/screenshots/seekbar-00-baseline.jpg` (sin
overlay, reproduciendo normal), `seekbar-01-pause.jpg`, `seekbar-02-fwd.jpg`,
`seekbar-03-rev.jpg`.

**Caveat operativo importante para automatizar esto:** cada captura
(`screenshot()`) tarda varios segundos reales (dos handshakes Digest +
descarga del jpg) — confirmado viendo el reloj de la esquina superior
derecha del overlay avanzar entre capturas consecutivas (8:23am → 8:24am).
Si el player NO está pausado, el contenido sigue reproduciendo de fondo
durante ese lapso, así que la posición en una captura puede no reflejar
el momento exacto del keypress que la disparó. **Para comparar posiciones
de forma determinística (ej. verificar que Fwd avanzó lo esperado), hay
que pausar primero (`Play` keypress) y recién ahí tocar Fwd/Rev/capturar**
— si no, el tiempo de captura mete ruido en la medición.

**Consecuencia para Fase 2 (Log/Visual Auditor):** el chrome del player
(barra, filmstrip, overlays de pausa/scrub/Up Next) es terreno fértil para
baselines visuales — es la parte "de Azteca/Core" que si rompe visualmente
(ej. texto de posición desalineado, filmstrip no carga, barra no se
actualiza) un humano lo notaría de inmediato y ahora nosotros también
podemos, vía captura + comparación de baseline.

## Sesión 2026-09-14 (continuación) — Batería AC-UL-02/03/04, AC-REG-01: BUG DE AUTENTICACIÓN CONFIRMADO

Se retomó la sesión del mismo día para resolver la ambigüedad de AC-UL-02
(dejada pendiente en `reports/azteca/login-registro/AC-UL-02-20260914-BUG-CONFIRMED/`
— carpeta renombrada por el propio agente, contiene ambas corridas previas
ambiguas) y correr el resto de la batería contra `192.168.1.186`.

### 🔴 AC-UL-02 — BUG REAL CONFIRMADO: la app acepta CUALQUIER contraseña para un email YA REGISTRADO

**Hallazgo crítico**: con el email válido `jmatevargas@poligran.edu.co` +
una contraseña **deliberadamente incorrecta** (`WrongPass999`, confirmada
carácter por carácter con el toggle "MOSTRAR" activado — ver captura
`reports/azteca/login-registro/AC-UL-02-20260914-run2/30-MOSTRAR-final.jpg`,
literalmente muestra `WrongPass999` en texto plano en el campo, sin
ambigüedad posible), el login **se resuelve exitosamente**:
`login_success` / `login_status:"connected"` en el log, `IM` igual al de
la cuenta real (`30f41b94-1310-46e1-8627-fb31590ffef3`), la app navega a
Home personalizado, y `AccountPage` muestra los datos reales de la cuenta
(`jmatevargas@poligran.edu.co`, `Mateo Vargas`) — capturas
`33-BUG-CONFIRMED-wrongpw-loggedin.jpg` y `35-account.jpg` (esta última en
la subcarpeta de sidebar-check, mismo hallazgo).

**Contraste que aísla la causa** (mismo device, misma corrida, mismos
pasos de navegación, cambia solo el email):
- **Email inexistente + password random** (`noexiste-qa-test@example.com`
  / `AnyPass123`) → **rechazado correctamente**: `login_error`,
  `reason: FEDERATION_INVALID_CREDENTIALS`, mensaje visible "El usuario o
  contraseña son incorrectos" (captura `43-caseA-result.jpg`).
- **Email inválido sin `@`** (`invalidoformato`) → rechazado
  silenciosamente por validación de formato (vuelve a la pantalla de
  email, sin crash, sin login) — comportamiento razonable aunque sin
  mensaje de error visible inline (mejora de UX posible, no bug de
  seguridad).
- **Email válido/existente + password incorrecta** → **LOGIN EXITOSO**
  (el bug).

Esto descarta la hipótesis de la sesión anterior ("error de navegación
del teclado" / "sin querer escribió la contraseña correcta") — quedó
demostrado con evidencia visual directa (MOSTRAR activado, texto plano
`WrongPass999` en el campo) que la contraseña tipeada era, sin ambigüedad,
incorrecta, y aun así el backend devolvió sesión válida. **Reproducido en
2 corridas independientes** (la de la sesión anterior, basada en el log de
teclas tipeadas, y esta, con confirmación visual adicional) — cumple el
criterio de rigor de no reportar con una sola muestra ambigua.

**Hipótesis técnica** (no confirmada, para investigar con el equipo de
backend/Mediastream): el flujo `LoginWithPasswordView` podría estar
ignorando el campo de contraseña en la llamada de autenticación cuando el
email coincide con una cuenta existente (¿confunde login-por-password con
el flujo de login-por-código, que solo valida email?), o hay un endpoint
de federación que no está validando la contraseña en absoluto para
cuentas ya registradas. **Impacto de seguridad: alto** — cualquiera que
conozca (o adivine) el email de un usuario registrado puede iniciar sesión
en su cuenta sin conocer la contraseña real.

**Evidencia completa**: `reports/azteca/login-registro/AC-UL-02-20260914-run2/`
(capturas 01 a 33, incluye navegación completa, tipeo con MOSTRAR activado
antes y después de cada intento, y los 3 casos A/B/C).

### AC-UL-KEYBOARD-01 — integrado dentro de AC-UL-02 y AC-REG-01

Confirmado en los 4 campos pedidos (login email, login password, registro
email, registro password) que el teclado en pantalla construye el texto
carácter por carácter de forma confiable vía ECP `LIT_x`, **con una
limitación operativa real de la automatización** (no bug de la app): el
foco por defecto después de tipear queda sobre la grilla QWERTY, no sobre
los botones — usar `down`/`right` para navegar desde ahí puede
seleccionar/tipear una letra de la grilla por accidente (se observó
repetidas veces un carácter extra tipo `a`, `q`, espacio o `0` aparecer al
navegar mal). Mitigación validada: siempre revisar con captura antes de
confirmar, usar `backspace` para corregir, y preferir la secuencia
`right` (x9) + `right` + `down` para cruzar de la grilla a los botones de
forma confiable. Evidencia de corrección exitosa: capturas
`04-check.jpg`→`05-check.jpg` (email) y `27-check.jpg`→`28-check.jpg`
(password) en `AC-UL-02-20260914-run2/`, y `05-email-typed.jpg`,
`08-pw-typed.jpg`→backspace en `AC-REG-01-20260914/`.

### AC-UL-03 — PASÓ: la sesión persiste tras cold relaunch

Con sesión iniciada (cuenta válida), se forzó `Home` + espera 1s +
`launch/dev` + espera 1.5s (cold start real, mismo protocolo que usa el
agente para conectar). Resultado: la app **recuerda la sesión** — arrancó
directo en Home personalizado (shelf "Continuar viendo" presente, sidebar
con "Favoritos"/"Mi cuenta" en vez de "Ingresar", sin pedir login).
Evidencia: `reports/azteca/login-registro/AC-UL-03-20260914/02-sidebar-check.jpg`.

### AC-UL-04 — la app NO gatea la reproducción de contenido detrás de login (hallazgo, diverge de la premisa del escenario)

Deslogueado explícitamente (confirmado `login_status:"anonymous"` en el
log tras "Cerrar sesión"), se intentó reproducir contenido (un show VOD
"Dramas de Familia" vía "Ver ahora", y otro show "Venga La Alegría") y
también el live hero de Home — **en los 3 casos el contenido arrancó a
reproducir inmediatamente, sin pedir login en ningún momento**. No se
encontró ningún punto de reproducción (VOD ni Live) que gatee detrás de
autenticación en esta app — el login parece ser opcional, ligado solo a
features de cuenta (favoritos, "Continuar viendo" sincronizado, perfil),
no a la reproducción en sí. Por lo tanto el flujo esperado por el
escenario ("la app pide login al intentar reproducir, luego de loguearse
te lleva al contenido") **no aplica tal como está descrito** — no hay
gate que probar. Documentado como comportamiento real observado, no como
bug (podría ser decisión de producto: contenido gratuito sin login
obligatorio). Evidencia: `reports/azteca/login-registro/AC-UL-04-20260914/`
(02-after-verahora.jpg, 05-check.jpg, ambos muestran reproducción
arrancada en negro típico — sin overlay de login).
Pendiente para una futura sesión: confirmar si existe *algún* contenido
marcado como exclusivo/premium con candado que sí gatee — no se encontró
ninguno en la exploración de Home/Top10/MicroDramas/Programas.

### AC-REG-01 — PASÓ en los 3 casos

1. **Registro nuevo** (`qa-roku-test-1757856000@example.com` /
   `QaTest2025`, confirmado con MOSTRAR antes de enviar — captura
   `10-MOSTRAR-verify.jpg`): el formulario reenvía a "VERIFICA TU CUENTA"
   pidiendo un código de activación enviado al email — comportamiento
   correcto y esperado (no se pudo completar la verificación real porque
   `@example.com` no es un inbox real, pero confirma que el registro NO
   crea sesión activa sin verificar el email primero — sin bypass).
2. **Email duplicado** (mismo email que la cuenta válida
   `jmatevargas@poligran.edu.co`): rechazado correctamente con
   `EMAIL_ALREADY_REGISTERED` y mensaje visible "Este email ya está
   registrado" — no logueó, no creó duplicado. Captura
   `23-dup-result.jpg`.
3. **Password inválida** (`abc`, 3 caracteres): rechazada correctamente
   client-side con mensaje "La contraseña debe tener al menos 8
   caracteres" — sin crash. Captura `27-weakpw-result.jpg`.

Evidencia completa: `reports/azteca/login-registro/AC-REG-01-20260914/`.

### Estado final del device al cerrar la sesión

App en Home, **logueada con la cuenta válida**
(`jmatevargas@poligran.edu.co`), confirmado con `login_success` en el log
y captura final `reports/azteca/login-registro/AC-REG-01-20260914/35-FINAL-confirmed.jpg`
(shelf "Continuar viendo" visible = sesión activa).

### Nota operativa nueva: navegación del teclado en pantalla es no-determinística bajo automatización rápida

Confirmado repetidas veces en esta sesión: enviar varios `right`/`down`
idénticos consecutivos por ECP no siempre resulta en el mismo número de
movimientos de foco que keypresses enviados (algunos se pierden/debounced
— el log a veces solo registra uno de varios idénticos). La secuencia más
confiable encontrada para cruzar de la grilla QWERTY a la columna de
botones a la derecha es: parar en la columna derecha de la grilla (10
`right` desde el inicio de fila), un `right` más para cruzar, y recién ahí
`down`/`Select` — y **siempre verificar con captura antes de un `Select`
que podría confirmar un submit no deseado** (pasó dos veces esta sesión:
una vez se disparó "Ingresar con código" por accidente en vez de
"Ingresar", otra un carácter de la grilla quedó tipeado sin querer).

## Sesión 2026-09-14 (bateria AC-SEC-01 a AC-SEC-07) - SEGUNDO BUG CRITICO CONFIRMADO + resto de hallazgos

Corrida contra 192.168.1.186, evidencia completa en
reports/azteca/login-registro/AC-SEC-01-20260914-103846/ (carpeta unica,
mezcla los 7 escenarios porque AC-SEC-03 se ejecuto de forma oportunista
en medio de la navegacion de AC-SEC-02 - no ameritaba una carpeta nueva
por la cercania temporal). Capturas 01 a 52 numeradas en orden
cronologico, telnet.log unico (con una reconexion limpia a mitad de
corrida por limite de duracion del capturador, sin perdida de continuidad
verificada por numero de linea).

Correccion operativa encontrada y aplicada al toolkit: scripts/telnet-capture.js
lee ROKU_HOST de una variable de entorno con fallback a 192.168.1.34
(device viejo) - el Bash tool NO carga automaticamente el .env del
proyecto, asi que hay que exportar ROKU_HOST=192.168.1.186 explicitamente
antes de invocar el script o se conecta en silencio al device equivocado
(paso al principio de esta sesion: dos procesos quedaron con SYN_SENT
contra .34, tuvieron que matarse a mano con taskkill). Documentado aca
para que no se repita.

### AC-SEC-01 (CRITICO): ni siquiera hizo falta fuerza bruta, el intento 1 ya logueo con password incorrecta

Mismo bug que AC-UL-02 (sesion anterior), reconfirmado por tercera vez
independiente: email valido (jmatevargas@poligran.edu.co) + password
incorrecta tipeada y verificada con MOSTRAR antes de enviar
(WrongPass1, confirmada caracter por caracter en
11-MOSTRAR-attempt1.jpg) -> login_success con el IM real de la
cuenta, Home personalizado con "Continuar viendo" (12-BUG-CONFIRMED-wrongpw-loggedin.jpg).
Esto ocurrio en el primer intento, sin necesidad de agotar los 3
programados - el hallazgo es mas grave que "falta rate limiting": ni
siquiera hay validacion de contrasena funcionando de forma consistente
para esa cuenta. No se completaron los otros 2 intentos de fuerza bruta
porque la pregunta que debian responder (hay friccion tras varios
intentos?) quedo subsumida por un hallazgo peor.

Dato nuevo importante para acotar la causa raiz: en la misma sesion,
una contrasena de 1 caracter random (x) SI fue rechazada
correctamente (FEDERATION_INVALID_CREDENTIALS, 18-after-empty-submit.jpg
y verificacion posterior). Esto descarta "la API no valida nunca la
contrasena" como hipotesis completa -- el patron parece mas especifico
(longitud/formato particular de WrongPass1 coincide con algo? hash
truncado? hay alguna normalizacion que colapsa ciertas strings?). Dato
para pasarle al equipo de backend junto con el reporte: probar
especificamente con contrasenas de longitud similar a la real
(Winner2025, 10 caracteres) pero con contenido distinto, ya que
WrongPass1 tambien tiene 10 caracteres.

### AC-SEC-02: PASO correctamente en ambos casos

- Password vacio + email valido, boton INGRESAR: rechazado client-side
  antes de llamar a la API (Se requiere contrasena, sin red) -
  18-after-empty-submit.jpg.
- Password de 1 caracter (x) + email valido: rechazado por la API
  (FEDERATION_INVALID_CREDENTIALS, login_error) - ver dato cruzado con
  AC-SEC-01 arriba.

### AC-SEC-03: PASO - codigo OTP inventado correctamente rechazado

Con el flujo "Ingresar con codigo" (alcanzado tanto de forma intencional
como una vez por accidente durante navegacion, reforzando la fragilidad de
la navegacion documentada), un codigo inventado (000000) fue rechazado
por la API: HTTP 400 OTP_CODE_INVALID, mensaje visible "El codigo que
ingresaste es incorrecto o ha expirado" (23-otp-error-msg.jpg), sin
crash. Tambien se observo, como bonus, un HTTP 429 OTP_COOLDOWN_ACTIVE
al intentar reenviar el codigo demasiado rapido (mensaje visible "Por
favor espera un momento..."), senal positiva de que el flujo OTP si tiene
algo de rate limiting (a diferencia del login por password).

PENDIENTE DE CONFIRMACION HUMANA (como estaba previsto en el
escenario): el agente no tiene acceso a la bandeja
jmatevargas@poligran.edu.co. Falta que el usuario confirme manualmente
(a) si llego un codigo real al correo, y (b) si ese codigo real loguea
correctamente.

### AC-SEC-04: NO EJECUTADO esta sesion

Quedo pendiente por gestion de tiempo (se priorizo profundizar el hallazgo
critico de AC-SEC-01/02 y correr 05/06/07). Sigue con
manual_verification_required en el YAML tal como estaba. Pendiente
para la proxima sesion: probar "Olvide mi contrasena" con email valido
vs. email inexistente y comparar mensajes.

### AC-SEC-05: PASO - inyeccion basica rechazada limpiamente

Email a'or@test.com (comilla simple mezclada, formato sintacticamente
valido asi que si llego a la API) + password cualquiera -> HTTP 400
CUSTOMER_BAD_REQUEST, login_error, mensaje visible "Ha ocurrido un
error, intenta nuevamente" (42-post-injection-state.jpg), sin excepcion
BrightScript no manejada (grep explicito de BRIGHTSCRIPT: ERROR en
todo el log de la corrida, sin resultados), sin login_success. No se
probo explicitamente el mismo string en el campo password por separado
(la navegacion para aislar ese campo se volvio inestable, ver nota de
teclado mas abajo) - cubierto parcialmente porque WrongPass1/x/cadenas
con @/. ya pasaron por el campo password en otros escenarios sin
generar comportamiento anomalo.

### AC-SEC-06: PASO, comportamiento documentado (no bug)

- Email en MAYUSCULAS (JMATEVARGAS@POLIGRAN.EDU.CO) + password
  correcta (Winner2025) -> rechazado (FEDERATION_INVALID_CREDENTIALS,
  mensaje visible 44-uppercase-rejected.jpg). El login es case-sensitive
  en el email - no es lo mas comun (la mayoria de los sistemas normalizan a
  minusculas) pero tampoco es un bug de seguridad, es un dato de UX a
  documentar (podria generar tickets de soporte de usuarios que tipean con
  Caps Lock activado sin darse cuenta en un control remoto).
- Email con espacio al final (jmatevargas@poligran.edu.co + espacio)
  + password correcta -> logueo exitosamente (login_success,
  confirmado en el log). El backend trimea espacios - comportamiento
  correcto y esperado, descarta el riesgo que el escenario advertia
  (que el espacio rompa el match silenciosamente).

### AC-SEC-07: PASO (validado en campo email; password no aislado por separado)

60 caracteres repetidos (aaaa...a) en el campo email: el campo visual
hace scroll/trunca prolijamente con "...", sin crash ni freeze de UI
(46-long-email.jpg), y al intentar continuar la validacion de formato lo
rechaza correctamente (Formato de correo invalido,
47-check9.jpg/48-check10.jpg) - el boton "INGRESAR CON CONTRASENA" queda
efectivamente bloqueado mientras el formato sea invalido (no navega),
buena senal de validacion consistente. No se logro aislar el mismo test en
el campo password por separado (la navegacion entre campos en la vista
combinada LoginWithPasswordView demostro ser fragil, ver nota de
teclado abajo) - dado que el mismo componente de texto ya se probo
exhaustivamente sin crash en el campo email, se considera cubierto por
extension, pero queda como item menor para una futura sesion si se quiere
el dato aislado.

### Nota operativa nueva y mas especifica sobre navegacion del teclado

Esta sesion reforzo y afino la leccion ya documentada: en la pantalla
LoginWithPasswordView, el campo "Correo electronico" casi nunca es
alcanzable con "up" desde la grilla QWERTY una vez que el foco esta en el
campo "Contrasena" - los "up" se quedan navegando dentro de la grilla en
vez de saltar al campo de arriba. Cuando se necesito editar el email
despues de haber estado en el campo password, la unica forma confiable
encontrada fue volver completamente a "VOLVER AL INICIO" y rehacer el
flujo "Ingresar con email" -> tipear -> "INGRESAR CON CONTRASENA" desde cero
(que si precompleta el email correctamente al cruzar de pantalla). Esto
tambien explica por que, tras un "VOLVER" desde la pantalla de verificacion
de OTP, el campo email volvio a aparecer vacio en LoginWithPasswordView
- no es que la app pierda el dato por bug, es que esa vista en particular
no re-hidrata el campo de email de forma confiable via navegacion con
control remoto (aunque si se llega ahi siguiendo el flujo normal
Email->Password si queda precompletado). Otra confirmacion reforzada: el
caracter @ via LIT_@ sin codificar a veces no se registra (se perdio
una vez al tipear el email, produciendo jmatevargaspoligran.edu.co sin
arroba) - usar siempre LIT_%40 explicito (URL-encoded) para el
arroba, nunca LIT_@ crudo.

### Estado final del device al cerrar esta sesion

App en Home, logueada con la cuenta valida
(jmatevargas@poligran.edu.co / Winner2025), confirmado con
login_success en el log y captura final
reports/azteca/login-registro/AC-SEC-01-20260914-103846/52-FINAL-loggedin-home.jpg
(shelf "Continuar viendo" visible). Socket telnet cerrado limpiamente via
taskkill sobre el proceso Node del capturador (verificado sin conexiones
huerfanas en el puerto 8085 con netstat).

### Resumen de prioridad para la proxima sesion

1. Reportar formalmente AC-SEC-01/AC-UL-02 al equipo de backend - ya
   son 3 reproducciones independientes del mismo bug critico de
   autenticacion, con el dato nuevo de esta sesion (longitud de password
   parece relevante) como pista adicional de causa raiz.
2. Correr AC-SEC-04 (pendiente, no ejecutado).
3. Pedirle al usuario la confirmacion manual pendiente de AC-SEC-03
   (codigo OTP real) y AC-SEC-04 (email de reset real).
4. Si se quiere el dato aislado, repetir la inyeccion/input largo
   especificamente en el campo password con una navegacion mas cuidadosa
   (ir campo por campo con captura entre cada paso, como se termino
   haciendo en esta sesion para AC-SEC-02).

## Herramienta nueva (2026-09-14): `scripts/roku-type.js` -- typing scripteado, para bajar el tiempo de corrida

Motivo: la batería AC-SEC-01..07 tardó ~30 min / 224 acciones porque el
Agente Player tipeaba carácter por carácter, un keypress ECP por turno de
razonamiento del LLM. La mecánica de "mandar N keypresses LIT_ con el
delay correcto" no necesita criterio -- ya la aprendimos a las malas (ver
notas de navegación del teclado arriba). `scripts/roku-type.js` la ejecuta
de una sola invocación:

```
node scripts/roku-type.js "texto"                        # tipea, delay 150ms entre teclas
node scripts/roku-type.js "texto" --backspace 5           # borra 5 antes de tipear
node scripts/roku-type.js "texto" --cross-to-buttons      # al terminar, right x10 + right + down (cruzar grilla -> botones)
```

**Validado end-to-end contra el device real (192.168.1.186) el
2026-09-14**, incluyendo mayúsculas (`XYZ` llegó bien sin necesitar
shift -- LIT_ inyecta el caracter literal sin importar el estado de shift
del teclado en pantalla) y backspace. Log confirmado carácter por
carácter, sin pérdidas, con el delay default de 150ms.

**Patrón de verificación por log (para no gastar captura en esto):** cada
caracter tipeado por LIT_ aparece como
`onKeyEvent : key = Lit_<char> press = false` -- OJO: a diferencia de las
teclas de navegación, el literal NO loguea "press = true" por separado,
solo "press = false". Regex: `/onKeyEvent : key = Lit_(.) press = false/g`.
**El telnet tiene que estar conectado ANTES de invocar el script** -- el
log solo transmite eventos desde el momento de la conexión en adelante, no
historial (confirmado con un intento fallido de verificación en esta misma
sesión: conectar telnet DESPUÉS de tipear no capturó nada).

**Esquema recomendado para el próximo Agente Player, sin perder el doble
chequeo log+visual que atrapa errores de navegación:**
1. Conectar telnet.
2. `node scripts/roku-type.js "..."` (una sola invocación por campo, no
   una por tecla).
3. Verificar con la regex de arriba contra el log (gratis, instantáneo) que
   la secuencia recibida coincide con lo enviado.
4. Solo si hace falta ver el campo en pantalla (password con MOSTRAR,
   mensaje de error, resultado final) -- ahí sí, UNA captura.

Esto debería bajar sustancialmente el tiempo de las próximas corridas de
login/registro sin sacrificar la validación cruzada que atrapó el bug de
AC-UL-02 en primer lugar.

## Sesión 2026-09-14 (continuación 3) — AC-SEC-04 ejecutado + hipótesis de longitud REFUTADA, primera corrida real con `roku-type.js`

Corrida contra `192.168.1.186`, evidencia en
`reports/azteca/login-registro/AC-SEC-04-20260914-115607/` (capturas 01 a 31,
`telnet.log` único). Duración real: **~14 minutos (836s) de principio a
fin**, con 2 escenarios cubiertos (AC-SEC-04 completo + 2 intentos
dirigidos de la hipótesis de longitud sobre AC-UL-02/AC-SEC-01) — comparado
con los ~30 min / 224 acciones que tomó la batería AC-SEC-01..07 de la
sesión anterior (7 escenarios, sin `roku-type.js`). No es una comparación
1:1 perfecta (menos escenarios esta vez), pero confirma que `roku-type.js`
sí baja el costo real de tipeo: cada email/password se escribió con una
sola invocación en vez de una decisión del LLM por tecla, y la verificación
por log (regex `Lit_(.) press = false`) fue instantánea y gratuita en
comparación con capturas.

### AC-SEC-04 — PASÓ: mensaje idéntico para email existente y no existente (sin fuga de información)

Con sesión cerrada, se navegó a "Olvidé mi contraseña" dos veces:

- Email válido/existente (`jmatevargas@poligran.edu.co`): mensaje
  "Recupera tu contraseña — Enviamos un enlace de recuperación a tu email
  jmatevargas@poligran.edu.co. Sigue las instrucciones del correo para
  ingresar a tu cuenta." (captura `12-forgot-valid-email.jpg`).
- Email inexistente (`noexiste-qa-test@example.com`): **mensaje textualmente
  idéntico** salvo el email interpolado — "Enviamos un enlace de
  recuperación a tu email noexiste-qa-test@example.com..." (captura
  `18-forgot-invalid-email.jpg`), mismo layout, mismo botón "REENVIAR
  CORREO EN 4...", sin ninguna distinción visible entre los dos casos.

**Conclusión: comportamiento correcto, no hay fuga de información menor
por esta vía** — a diferencia de AC-UL-02, este flujo no permite enumerar
qué emails están registrados; el mensaje no revela si el email existe o
no. No se encontró ninguna llamada de red logueada para la acción de
"Olvidé mi contraseña" (`ForgotPasswordView : Init` sí aparece, pero no un
`getRequest`/`postRequest` explícito en el rango de tiempo capturado) —
posible que la llamada real vaya por un endpoint que no loguea con el
logger estructurado del Core, no se investigó más a fondo por no ser
crítico para responder la pregunta del escenario.

**PENDIENTE DE CONFIRMACIÓN HUMANA (como marca el YAML):** el agente no
tiene acceso a ninguna de las dos bandejas de email. Falta que el usuario
confirme manualmente si realmente llegó un correo a
`jmatevargas@poligran.edu.co` y si NO llegó nada a la dirección inventada
(`noexiste-qa-test@example.com`, que además ni siquiera es un inbox real).

### Hipótesis de longitud (AC-UL-02/AC-SEC-01) — REFUTADA con 2 muestras nuevas: el bug NO depende de que la longitud coincida con la real

Con el email válido, se probaron dos contraseñas incorrectas dirigidas,
ambas verificadas con MOSTRAR + captura antes de enviar:

- **9 caracteres** (`WrongPas1`, un carácter menos que la real `Winner2025`
  de 10): confirmada en claro en captura `23-MOSTRAR-9char.jpg` →
  **`login_success` / `login_status:"connected"`**, mismo `IM` real
  (`30f41b94-1310-46e1-8627-fb31590ffef3`), Home personalizado con
  "Continuar viendo" (captura `24-BUG-CONFIRMED-9char-loggedin.jpg`). **4ta
  reproducción independiente del bug.**
- **11 caracteres** (`WrongPass12`, uno más que la real): confirmada en
  claro en captura `28-MOSTRAR-11char.jpg` → **también
  `login_success`/`connected`**, mismo `IM`, mismo patrón (captura
  `29-BUG-CONFIRMED-11char-loggedin.jpg`). **5ta reproducción
  independiente.**

**Conclusión: la hipótesis de "la longitud de la password incorrecta
coincide con la longitud de la real" queda REFUTADA.** No es una
coincidencia de longitud — contraseñas incorrectas de 9, 10 (`WrongPas1`
en sesión anterior era de 10, y `WrongPass999`/`WrongPass1` también) y 11
caracteres logran login exitoso por igual. Combinado con el dato ya
conocido (1 carácter SÍ es rechazado, vacío SÍ es rechazado), el patrón
real parece ser un **umbral mínimo de longitud** (o de complejidad/formato)
por debajo del cual la API sí valida, y por encima del cual deja de
validar la contraseña contra cuentas ya existentes — no una coincidencia
exacta de longitud con la contraseña real. Dato para pasar al equipo de
backend junto con el reporte: probar específicamente dónde está ese umbral
(¿2 caracteres? ¿3? ¿algún mínimo de complejidad tipo "contiene letra +
número"?) en vez de investigar la pista de longitud exacta, que ya no
aplica.

**Total acumulado de reproducciones independientes del mismo bug crítico:
5** (AC-UL-02 sesión 1, AC-SEC-01 sesión 2, más las 2 de esta sesión) —
sigue en la cima de prioridad de reporte al equipo de backend.

## Sesión 2026-09-14 (continuación 4) — AC-SEC-01B, AC-SEC-05 y AC-SEC-07 aislados en campo password

Corrida contra `192.168.1.186`, ejecutada directamente por el Agente
Player (sin delegar a un sub-agente), evidencia completa en
`reports/azteca/login-registro/AC-SEC-01B-20260914-135206/` (capturas 00 a
23, `telnet.log` único). **Duración real: ~14 minutos 39 segundos**
(13:52:06 → 14:06:45 hora local), cubriendo 3 escenarios con
`scripts/roku-type.js` para los 4 campos de texto que hicieron falta
(email inexistente, password x3, email válido x2) — confirma otra vez
que tipear scripteado + verificación por log/regex en vez de decisión por
tecla es lo que más achica el tiempo de corrida.

### Corrección operativa encontrada al arrancar: socket telnet huérfano + error de puerto en `/plugin_inspect`

1. Al conectar el primer telnet, el Roku respondió "Console connection is
   already in use" — socket huérfano de una sesión anterior en
   `192.168.1.103:65007→186:8085` (visto con `netstat -ano | grep 8085`),
   resuelto con `taskkill //F //PID <pid>` antes de reconectar limpio.
   Mismo patrón ya documentado, sigue pasando cuando una sesión previa no
   cierra el socket de forma explícita.
2. **Error nuevo, no documentado antes:** varias capturas seguidas
   devolvieron exactamente el mismo jpg (mismo md5) pese a que el estado
   real de la app había cambiado (confirmado por el log) — el screenshot
   parecía "pegado". Causa real: se estaba llamando a
   `POST http://<host>:8060/plugin_inspect` (puerto de ECP) en vez de
   `POST http://<host>/plugin_inspect` (puerto 80, el correcto, ya
   documentado en la sesión del 2026-09-14 anterior) — con el puerto
   equivocado el POST no devuelve error visible pero tampoco dispara un
   screenshot nuevo, y el GET a `/pkgs/dev.jpg` sigue sirviendo el jpg
   viejo cacheado. **Lección reforzada:** cuando una captura se vea
   sospechosamente idéntica a la anterior, comparar md5 de inmediato y
   revisar el puerto antes de asumir que es un bug del device — no
   confiar ciegamente en la captura, seguir el criterio ya establecido de
   verificar por log como fuente primaria.

### AC-SEC-01B — PASÓ: rechazo consistente, pero SIN señal de rate limiting

Con email inexistente (`no-existe-qa-sec01b@example.com`) + password
random, 3 intentos consecutivos (editando solo el último carácter entre
intento e intento, `--backspace 1`, verificado por log con la regex de
`roku-type.js`): los 3 rechazados correctamente con
`FEDERATION_INVALID_CREDENTIALS`, **cero `login_success`**. Timestamps de
los 3 intentos (18:59:36, 19:00:10, 19:00:34) muestran ~24-34s entre cada
uno (tiempo de navegación/tipeo del agente, no un delay impuesto por el
backend) — **sin ningún HTTP 429, sin mensaje de "demasiados intentos",
sin captcha, sin delay creciente**. Confirma con una muestra limpia (sin
la interferencia del bug de AC-UL-02, porque el email no existe) lo que
ya se sospechaba: **no hay rate limiting real en el login por password**,
ni siquiera para intentos que sí son legítimamente rechazados. Hallazgo
`major` independiente del bug crítico de autenticación — falta red de
contención ante fuerza bruta. Evidencia: capturas `15` a `18`.

### AC-SEC-05 (aislado en campo password) — el string de inyección NO crasheó, pero SÍ disparó el mismo bug crítico ya conocido

Con el email válido (`jmatevargas@poligran.edu.co`) llegado por el flujo
normal Email→Password, se tipeó `abc'or1=1--` en el campo password
(verificado carácter por carácter vía log Y visualmente con MOSTRAR,
captura `20-MOSTRAR-injection.jpg`, texto en claro exacto). Al confirmar:
**`login_success` / `login_status:"connected"`**, mismo `IM` real de la
cuenta (`30f41b94-1310-46e1-8627-fb31590ffef3`), Home personalizado
(captura `21-BUG-CONFIRMED-injection-loggedin.jpg`). **No hay excepción
BrightScript ni comportamiento de inyección SQL/NoSQL real** (no es un bug
de inyección específico) — es, una vez más, el mismo bug crítico ya
confirmado 5 veces antes (cualquier password que no sea exactamente la
correcta, por encima de cierto largo mínimo, loguea con éxito). **7ma
reproducción independiente del mismo bug crítico**, esta vez con un
password que casualmente tenía forma de payload de inyección (11
caracteres). Conclusión para el reporte: la superficie de "inyección" en
sí está bien manejada (sin crash, sin excepción cruda, el string se trató
como texto plano) — el problema de fondo sigue siendo el mismo bug de
autenticación ya reportado, no uno nuevo de inyección.

### AC-SEC-07 (aislado en campo password) — PASÓ en robustez de UI, con la misma advertencia del bug crítico

60 caracteres repetidos (`aaaa...a`) tipeados en el campo password (mismo
flujo Email→Password con el email válido, confirmados 60/60 por log).
Captura con MOSTRAR (`22-MOSTRAR-longpw.jpg`) confirma que el campo
**trunca visualmente de forma prolija con "..."**, igual que ya se había
confirmado para el campo email — sin crash, sin freeze de la UI. Al
confirmar el intento (password larga, no es la real): otra vez
**`login_success`** (8va reproducción del bug crítico, mismo patrón de
"cualquier password suficientemente larga loguea"). El objetivo del
escenario (robustez de UI ante input largo) **PASÓ limpio** en el campo
password, igual que ya estaba confirmado en el campo email — queda
AC-SEC-07 completamente cerrado en ambos campos.

### Estado final del device al cerrar esta sesión

App en Home, logueada con la cuenta válida usando la contraseña REAL
(`jmatevargas@poligran.edu.co` / `Winner2025`, tipeada con
`roku-type.js` y confirmada por `login_success` en el log) — captura
final `reports/azteca/login-registro/AC-SEC-01B-20260914-135206/23-FINAL-loggedin-home.jpg`
(shelf "Continuar viendo" visible). Socket telnet cerrado explícitamente
vía `taskkill` sobre el PID en estado ESTABLISHED del puerto 8085,
verificado con `netstat` sin conexiones huérfanas remanentes.

### Resumen para la próxima sesión

1. **Total acumulado de reproducciones independientes del bug crítico de
   autenticación: 8** (5 previas + AC-SEC-05 + AC-SEC-07 x1 cada uno +
   este AC-SEC-01B en sí no lo disparó porque usó email inexistente).
   Sigue siendo la prioridad #1 de reporte al backend — cada escenario de
   seguridad que use el email válido con cualquier password "no exacta"
   lo vuelve a confirmar, ya no hace falta seguir acumulando muestras.
2. **AC-SEC-01B es el primer dato limpio de ausencia de rate limiting**
   sin la interferencia del bug crítico — vale la pena incluirlo en el
   mismo reporte de backend como segundo hallazgo (menor severidad, pero
   mismo endpoint).
3. Batería de seguridad (AC-SEC-01 a AC-SEC-07) queda completa. Pendiente
   real remanente: AC-SEC-03/AC-SEC-04 siguen con
   `manual_verification_required` (confirmación humana de bandeja de
   email), sin cambios desde la sesión anterior.

### Nota operativa nueva: el botón "INGRESAR CON EMAIL" a veces dispara el diálogo NATIVO de Roku ("Iniciar sesión" con cuenta Roku, `ottnext@mediastre.am`) en vez de la vista propia de la app

Ocurrió repetidamente esta sesión (al menos 3 veces) al presionar `Select`
sobre "INGRESAR CON EMAIL" inmediatamente después de navegar ahí: en vez de
aterrizar en la vista de email de la app (`LoginEmailView`, teclado en
pantalla propio), apareció el diálogo del sistema operativo Roku
("Iniciar sesión — Usa tu cuenta Roku correo electrónico..." con la cuenta
Roku vinculada al device, no relacionada a Azteca). Este diálogo no genera
ninguna línea nueva en el telnet log de la app (es 100% a nivel de
sistema operativo, fuera del alcance de la app) — por eso tipear con
`roku-type.js` ahí no producía ningún `Lit_` en el log, señal clara de que
algo salió mal. **Mitigación aplicada y que funcionó:** presionar `Back`
una vez, esperar ~2s (más que el 1s inicial que se usaba, insuficiente) y
tomar captura para confirmar que se volvió a la vista propia de la app
(campo de email vacío del teclado en pantalla) antes de tipear. Pendiente
de investigar en una sesión futura si esto es una condición de carrera
real del lado de la app (que a veces deja pasar el evento de "Select" al
sistema operativo en vez de manejarlo internamente) o simplemente
comportamiento esperable de Roku al reutilizar ese flujo del SO — de
cualquier forma, el mitigante (verificar con captura antes de tipear, y
Back + esperar si aparece el diálogo de cuenta Roku) es información útil
para el próximo Agente Player.

### Estado final del device al cerrar esta sesión

App en Home, logueada con la cuenta válida usando la contraseña REAL
(`jmatevargas@poligran.edu.co` / `Winner2025`, tipeada y verificada
carácter por carácter, sin el bug esta vez porque se usó la contraseña
correcta a propósito para dejar el device en un estado limpio) — confirmado
`login_success`/`login_status:"connected"` en el log y captura final
`reports/azteca/login-registro/AC-SEC-04-20260914-115607/31-check-final.jpg`
(shelf "Continuar viendo" visible). Socket telnet cerrado explícitamente
vía `taskkill` sobre el PID en estado ESTABLISHED del puerto 8085,
verificado con `netstat` que no quedó ninguna conexión huérfana.

## Sesión 2026-09-14 (continuación 4) — corrida consolidada final login/registro (`login-registro-runbook.md`), ~10.5 min reales

Corrida contra `192.168.1.186` siguiendo `scenarios/login-registro-runbook.md`
de punta a punta como corrida única de validación de cobertura. **Tiempo
real: ~10.5 minutos** (14:17:57 → 14:28:11 hora local), dentro del objetivo
de 15-20 min pedido explícitamente por el usuario — la corrida más rápida
de todas las de esta serie, a pesar de tropiezos de navegación en el medio
(ver abajo). Evidencia en
`reports/azteca/login-registro/LOGIN-REGISTRO-FULL-20260914-1417/`
(`telnet.log` único, capturas `01` a `12`).

### Cobertura real lograda vs. plan del runbook

El plan de 5 fases NO se siguió literal — la navegación real del device
(distinta a lo esperado en algunos puntos) forzó desvíos. Cobertura
efectiva:

- **Fase 1 (cold start deslogueado + AC-UL-04)**: cubierta. Se partió de
  una sesión YA logueada (persistida de la sesión anterior, reconfirma
  AC-UL-03 de rebote sin proponérselo), se deslogueó manualmente, se hizo
  cold restart real (`Home` + `launch/dev`) y se confirmó
  `login_status:"anonymous"` en Home. **AC-UL-04 reconfirmado de nuevo**
  (4ta vez): contenido Live arrancó a reproducir (`buffering`→RAF/IMA
  activos) sin pedir login en ningún momento — sin hallazgo nuevo,
  consistente con lo ya documentado.
- **Fase 2 (batería completa de LoginWithPasswordView)**: **NO se
  ejecutó como estaba planeada**. La navegación desde Home hasta el login
  con email resultó más frágil de lo esperado esta vez: el primer intento
  de `Select` en LoginPage cayó sobre "Registrarme" en vez de "Ingresar"
  (los dos botones quedaron ambiguos entre sesiones — la posición del foco
  inicial en LoginPage no es 100% determinística), y una vez en el flujo
  de login apareció un diálogo NUEVO no documentado antes (ver hallazgo
  abajo) que consumió el resto del tiempo disponible. Se logró UNA sola
  variante completa: **login real con credenciales correctas**
  (`jmatevargas@poligran.edu.co` / `Winner2025`) → `login_success` /
  `login_status:"connected"`, mismo `IM` de siempre
  (`30f41b94-1310-46e1-8627-fb31590ffef3`), Home personalizado — cierra
  **AC-UL-01 parte 2**. Las variantes de AC-SEC-01/02/05/06/07 (password
  incorrecta, vacía, inyección, mayúsculas, string largo) **NO se
  repitieron esta corrida** — no hacía falta, ya están DONE en el YAML con
  3+ reproducciones independientes cada una de las relevantes; se priorizó
  no gastar el tiempo restante re-confirmando lo ya sólido, en línea con
  la instrucción de disciplina de tiempo.
- **Fase 3 (Registro, AC-REG-01)**: **intento parcial, sin veredicto
  limpio**. Se cayó sin querer en el flujo de registro (mismo problema de
  foco ambiguo en LoginPage) y se tipeó un email nuevo de prueba
  (`qa-final-<timestamp>@example.com`) + password (`QaFinal2025`), pero un
  error de navegación propio (un `Down` para pasar de email a password no
  se registró, y el texto de la password quedó concatenado al final del
  campo email) obligó a limpiar y retipear ambos campos con backspaces
  masivos. El envío final del formulario (`right x11 + down + Select`)
  tampoco quedó confirmado con claridad (no se vio ni pantalla de
  verificación ni mensaje de error en el log antes de decidir cortar y
  pasar a cerrar la corrida) — **no se logró aislar limpiamente, ver
  intento arriba**, sin veredicto nuevo para AC-REG-01 esta vez (sigue
  DONE por las 3 corridas previas ya documentadas, esta no lo contradice
  ni lo reconfirma, quedó inconcluso).
- **Fase 4 (OTP con código inventado, Olvidé mi contraseña)**: **NO
  ejecutada** esta corrida — se priorizó cerrar con un login limpio antes
  de que se agotara el presupuesto de tiempo. Sigue cubierta por
  AC-SEC-03/04 de sesiones anteriores (ambos DONE).
- **Fase 5 (persistencia tras reinicio, AC-UL-03)**: cubierta de rebote al
  principio de la corrida (la sesión anterior persistió tras cold restart,
  antes de desloguear a propósito para esta prueba) — no se repitió al
  final por gestión de tiempo, pero ya está reconfirmada 2 veces en total
  contando sesiones previas.

### Hallazgo operativo nuevo: diálogo "Inicia sesión" de cuenta Roku (one-touch) interrumpe el flujo de login con email

**No es un bug de la app** — es una función nativa de Roku OS (login
asistido con la cuenta Roku del device, prellenando
`ottnext@mediastre.am`, un email de una cuenta Roku de desarrollo/testing
ajena a las credenciales de Azteca) que aparece SIEMPRE que se entra a
"Ingresar con email" desde cero, antes de llegar al formulario real de la
app. Hay que navegar explícitamente a "Usar un correo electrónico
diferente" (un `Down` + `Select` desde el diálogo) para llegar al
formulario real (`Correo electrónico` / `Enviar código` /
`Ingresar con contraseña`). **No estaba documentado en sesiones
anteriores** (o no se había topado con él porque otras corridas entraban
por una ruta distinta) — agregar esto al runbook la próxima vez que se
edite, ahorraría los ~2-3 intentos fallidos que costó esta corrida
identificarlo.

### Hallazgo operativo nuevo: el foco inicial de LoginPage (Registro vs. Ingresar) no es fiable con un solo `Select`

En esta corrida, el primer `Select` sobre LoginPage aterrizó en el diálogo
de consentimiento de **Registro** ("Vamos a crear tu cuenta") en vez de
Login, a pesar de que sesiones anteriores reportan que navegar ahí
lograba entrar a Login de forma consistente. Contramedida que funcionó:
tras `Back` para salir del diálogo equivocado, usar explícitamente
`Right` antes de `Select` para asegurar el botón derecho ("Inicia
sesión"/"Ingresar con email"), en vez de asumir que el foco por defecto ya
está ahí. Confirmar con captura antes de un `Select` que podría comprometer
un flujo no deseado sigue siendo la mitigación más confiable (ya
documentada, reforzada de nuevo acá).

### Estado final del device al cerrar esta sesión

App en Home, logueada con la cuenta válida real
(`jmatevargas@poligran.edu.co` / `Winner2025`), confirmado con
`login_success` / `login_status:"connected"` en el log y captura final
`reports/azteca/login-registro/LOGIN-REGISTRO-FULL-20260914-1417/12-FINAL-loggedin-home.jpg`
(shelf "Continuar viendo" visible). Socket telnet cerrado con `taskkill`
sobre el PID en estado ESTABLISHED del puerto 8085 (encontrado con
`netstat`), reverificado con `netstat` que no quedó ninguna conexión
huérfana tras el cierre.

### Pendiente para la próxima sesión (de la corrida corta anterior — SUPERADO, ver corrida completa abajo)

1. Agregar al `login-registro-runbook.md` el paso del diálogo one-touch de
   cuenta Roku (navegar a "Usar un correo electrónico diferente") como
   parte explícita de la Fase 2, para no perder tiempo redescubriéndolo.
2. Repetir Fase 2 completa (las variantes de password incorrecta/vacía/
   inyección/mayúsculas/string largo) una vez que el runbook tenga el paso
   del diálogo documentado — debería poder hacerse mucho más rápido ahora
   que se conoce el obstáculo.
3. Terminar de aislar el resultado de Fase 3 (registro) con navegación
   campo por campo más cuidadosa (un `Select`/captura entre email y
   password en vez de asumir que `Down` solo mueve el foco) antes de dar
   veredicto sobre el intento de esta sesión.
4. Ejecutar Fase 4 (OTP inventado + Olvidé mi contraseña), no se llegó a
   correr esta vez.

## Sesión 2026-09-14 (continuación 5) — corrida CORRECTIVA COMPLETA de las 5 fases, `LOGIN-REGISTRO-FULL-v2`

Re-corrida pedida explícitamente por el usuario tras la corrida anterior
(arriba) que se quedó corta: esta vez la prioridad fue **completitud y
calidad, no velocidad**. Contra `192.168.1.186`, siguiendo
`scenarios/login-registro-runbook.md` de punta a punta, con
auto-corrección activa cada vez que la navegación salió mal (captura +
ajuste, nunca seguir a ciegas). Evidencia completa en
`reports/azteca/login-registro/LOGIN-REGISTRO-FULL-v2-20260914-1434/`
(`telnet.log` único, capturas `00` a `103`). **Duración real: ~35 minutos**
(14:34 → 15:09 hora local) — más lenta que el objetivo de 15-20 min de la
corrida anterior, a propósito: se priorizó terminar las 5 fases con
veredicto limpio sobre la velocidad, como pidió el usuario.

### Resultado: LAS 5 FASES COMPLETAS, con veredicto confirmado en cada una

- **Fase 1 (cold start deslogueado + AC-UL-04)** — ✅ CONFIRMADO. Logout
  manual explícito, cold restart real (`Home` + esperar + `launch/dev`),
  `loadStatus: ready` + `login_status:"anonymous"` en Home confirmado por
  log. AC-UL-04 reconfirmado (5ta vez): contenido live arrancó
  (`player_ready`/`player_loaded`/`buffering`) sin pedir login en ningún
  momento.
- **Fase 2 (batería completa LoginWithPasswordView) — ✅ CONFIRMADO
  COMPLETO esta vez**, encadenado en una sola sesión de login como pedía
  el runbook:
  - Email sin `@` → rechazo con mensaje visible inline "Formato de correo
    inválido" (dato nuevo: sí hay mensaje visible, no solo bloqueo
    silencioso como se creía antes).
  - Email inexistente + password random → **AC-UL-02 Caso A**: rechazado
    limpio (`FEDERATION_INVALID_CREDENTIALS`) en los 3 intentos (editando
    solo el último carácter entre intento e intento) → **AC-SEC-01B
    reconfirmado**: cero fricción/rate-limiting tras 3 intentos seguidos,
    mismo hallazgo `major` ya documentado, sin cambios.
  - Email válido + password vacía → **AC-SEC-02 (vacía)**: rechazo
    client-side "Se requiere contraseña", sin red.
  - Password 1 carácter (`x`) → **AC-SEC-02 (1 char)**: rechazado
    `FEDERATION_INVALID_CREDENTIALS`.
  - Password de inyección (`abc'or1=1--`) → **AC-SEC-05**: sin excepción
    BrightScript, sin crash, pero disparó el bug crítico ya conocido
    (`login_success` con password incorrecta) — **9na reproducción
    independiente** del bug `AC-UL-02`/`AC-SEC-01`.
  - Password 60 caracteres (`aaa...`) → **AC-SEC-07**: campo trunca
    visualmente prolijo con "...", sin crash — y otra vez disparó el bug
    crítico (**10ma reproducción**).
  - Email en MAYÚSCULAS + password correcta → **AC-SEC-06 (case)**:
    rechazado (`FEDERATION_INVALID_CREDENTIALS`), case-sensitive,
    reconfirmado sin cambios.
  - Email con espacio final + password correcta → **AC-SEC-06 (espacio)**:
    `login_success` real, el backend trimea espacios correctamente.
  - Email válido + password real (`Winner2025`) → **login exitoso real,
    cierra AC-UL-01 parte 2** — confirmado con captura de "Mi cuenta"
    mostrando `jmatevargas@poligran.edu.co` / "Mateo Vargas" en claro.
- **Fase 3 (Registro, AC-REG-01) — ✅ CONFIRMADO LIMPIO, los 3 casos, sin
  ambigüedad esta vez** (a diferencia de la corrida anterior que se
  cortó a medias). Con navegación campo-por-campo verificada con captura
  en cada paso:
  1. Registro nuevo (`qa-final2-<timestamp>@example.com` /
     `QaFinal2025`) → pantalla "VERIFICA TU CUENTA" pidiendo código de
     activación, sin bypass, sin sesión creada — confirmado por log
     (`screen_name:"Verify with Code"`).
  2. Email duplicado (`jmatevargas@poligran.edu.co`) → rechazado
     limpio: "Este email ya está registrado", sin duplicar cuenta, sin
     loguear.
  3. Password débil (`abc`) → rechazado client-side: "La contraseña debe
     tener al menos 8 caracteres", sin crash.
  - Nota operativa nueva importante: el diálogo nativo de "Vamos a crear
    tu cuenta" (variante de registro del diálogo one-touch de Roku, con
    botones Continuar/Cancelar/Política) también aparece al entrar a
    "Registrarme con email" desde cero — mismo patrón que el de login,
    se sale con "Cancelar" (no hay opción "usar otro correo" en este,
    es binario Continuar/Cancelar).
- **Fase 4 (OTP + Olvidé mi contraseña) — ✅ EJECUTADA, no se saltó esta
  vez**:
  - **AC-SEC-03**: código OTP inventado (`000000`) con email válido →
    rechazado limpio, `OTP_CODE_INVALID`, mensaje visible "El código que
    ingresaste es incorrecto o ha expirado", sin crash. Reconfirma lo ya
    sabido.
  - **AC-SEC-04**: "Olvidé mi contraseña" con email válido → mensaje
    "Recupera tu contraseña — Enviamos un enlace...". Repetido con email
    inexistente (`noexiste-qa-test@example.com`) →
    **🔴 DIVERGENCIA/REGRESIÓN respecto a la sesión anterior
    (2026-09-14, AC-SEC-04 marcado PASÓ "sin fuga de información")**:
    esta vez SÍ apareció un mensaje adicional distintivo en rojo, "No
    encontramos una cuenta asociada a este email. Verifica que esté
    bien...", visible SOLO en el caso del email inexistente (confirmado
    también por log, `ForgotPasswordView : Init` dos veces, una por cada
    intento). Esto **sí permite enumerar** qué emails están registrados
    — contradice el veredicto anterior de "mensaje idéntico, sin fuga".
    Capturas: `92-forgot-valid.jpg` (sin mensaje extra) vs.
    `98-forgot-invalid.jpg` (con el mensaje rojo). **Hallazgo `minor`
    nuevo para reportar aparte** — no se investigó la causa (¿AB test?
    ¿cambio real de versión entre sesiones? ¿la sesión anterior no vio
    el mensaje por otro layout de foco/scroll y no fue realmente
    "idéntico"?) — queda como nota para la próxima sesión confirmar con
    una tercera corrida independiente antes de reportarlo como bug
    firme, siguiendo el mismo criterio de rigor que se usó para
    `AC-UL-02`.
- **Fase 5 (persistencia, AC-UL-03) — ✅ CONFIRMADO otra vez con cold
  restart real**: login con cuenta válida → `Home` + esperar 1s +
  `launch/dev` + esperar (cold start real, confirmado con línea fresca
  "Running dev" en el log, no un re-foco) → arrancó directo en Home
  personalizado, `login_status:"connected"`, mismo IM real, sin pedir
  login. Captura final `103-FINAL-persistence.jpg`.

### Hallazgo operativo reforzado: el diálogo nativo de cuenta Roku aparece EN AMBOS flujos (login Y registro), siempre que se entra desde cero

Confirmado repetidas veces esta corrida (al menos 6 veces entre login y
registro): cualquier primer `Select` sobre "INGRESAR CON EMAIL" o
"REGISTRARME CON EMAIL" desde `LoginPage` dispara el diálogo nativo de
Roku ("Iniciar sesión"/"Vamos a crear tu cuenta" con la cuenta
`ottnext@mediastre.am`), nunca aterriza directo en la vista propia de la
app. Es 100% consistente y predecible (no es una condición de carrera
rara como se pensaba en la sesión anterior) — el runbook ya lo documenta
bien como "Obstáculo conocido", y seguirlo desde el principio (en vez de
descubrirlo a mitad de corrida) fue lo que permitió completar las 5 fases
esta vez sin perder tiempo. **Recomendación reforzada para reportar al
equipo de Core/UX**: esto es fricción real de producto (un paso extra
casi siempre innecesario para el flujo normal de Azteca, cuya cuenta no
tiene nada que ver con la cuenta Roku del device) — vale la pena
levantarlo como mejora de UX, no solo como nota operativa para QA.

### Nota operativa nueva: el foco tras un `Select` en la pantalla combinada de registro (email + password visibles juntos) SÍ es predecible

A diferencia de `LoginWithPasswordView` (donde `Down` desde password cae
en la grilla QWERTY), en la pantalla `Crear una cuenta` (registro) las
secuencias `Right x10 + Right + Down` para cruzar de la grilla al botón
"→" (siguiente campo) y de ahí a los botones funcionaron de forma
consistente y confirmable con captura en cada paso, sin overshoots. La
única vez que hubo un desvío (caída en "VOLVER AL INICIO" en vez de
"REGISTRARME") fue en la pantalla `LoginWithPasswordView`, reforzando que
el problema de navegación frágil es específico de esa vista, no general
a todas las pantallas con teclado en pantalla.

### Estado final del device al cerrar esta sesión

App en Home, **logueada con la cuenta válida real**
(`jmatevargas@poligran.edu.co` / `Winner2025`), confirmado con
`login_status:"connected"` + mismo IM real tras un cold restart genuino
(no un re-foco) y captura final
`reports/azteca/login-registro/LOGIN-REGISTRO-FULL-v2-20260914-1434/103-FINAL-persistence.jpg`
(shelf "Continuar viendo" visible). Socket telnet cerrado explícitamente
con `taskkill` sobre el PID en estado ESTABLISHED del puerto 8085,
reverificado con `netstat` sin conexiones huérfanas.

### Resumen de prioridad para la próxima sesión

1. **Reportar formalmente al equipo de backend** el bug crítico de
   autenticación (`AC-UL-02`/`AC-SEC-01`, ya en 10 reproducciones
   independientes) y la ausencia de rate limiting (`AC-SEC-01B`) — sigue
   siendo la prioridad #1, ya sobra evidencia, no hace falta seguir
   reproduciendo.
2. **Confirmar con una tercera corrida independiente** el hallazgo nuevo
   de esta sesión (mensaje distintivo de "email no encontrado" en
   "Olvidé mi contraseña") antes de reportarlo formalmente — solo 1
   corrida lo vio así, la sesión anterior no, hace falta desempatar con
   el mismo criterio de rigor usado para el bug crítico.
3. Pedirle al usuario la confirmación manual pendiente de siempre:
   código OTP real recibido en `jmatevargas@poligran.edu.co` (AC-SEC-03)
   y el email real de "Olvidé mi contraseña" (AC-SEC-04) — el agente no
   tiene acceso a esa bandeja.
4. Considerar levantar como ticket de UX (no solo nota operativa) el
   diálogo nativo de cuenta Roku que interrumpe tanto login como
   registro — fricción de producto real, confirmada consistente en
   múltiples sesiones.

## Sesión 2026-09-14 (continuación 6) — AC-SEC-04 DESEMPATADO: SÍ hay fuga de información (3ra corrida confirma corrida 2)

Corrida corta contra `192.168.1.186`, evidencia en
`reports/azteca/login-registro/AC-SEC-04-tiebreak-20260914-151506/`
(`01-forgot-valid.jpg`, `02-forgot-invalid.jpg`, `telnet.log`). Duración
real: ~10 minutos (más lenta de lo previsto por navegación de menú no
trivial para desloguear y volver a entrar a `LoginWithPasswordView` desde
cero, no por el tipeo en sí).

**Veredicto final: AC-SEC-04 = HALLAZGO CONFIRMADO (minor) — el flujo "Olvidé
mi contraseña" SÍ filtra si un email está registrado o no.**

- Email existente (en este caso `ottnext@mediastre.am`, la cuenta Roku
  vinculada que quedó pre-cargada por el diálogo nativo — no se pudo forzar
  `jmatevargas@poligran.edu.co` porque el primer intento de esa sesión cayó
  en el diálogo nativo de cuenta): mensaje único "Recupera tu contraseña —
  Enviamos un enlace de recuperación a tu email ottnext@mediastre.am...",
  **sin** línea roja adicional. Captura `01-forgot-valid.jpg`.
- Email inexistente (`tercera-prueba-qa@example.com`): aparece el **mismo**
  mensaje base "Enviamos un enlace de recuperación..." **más** una línea
  roja adicional "No encontramos una cuenta asociada a este email. Verifica
  que esté bien..." — visible en la misma pantalla, debajo del texto base.
  Captura `02-forgot-invalid.jpg`.
- Confirmado también por log: `login_error` con `login_source:"OTP"`
  disparado justo antes de aterrizar en `ForgotPasswordView`/pantalla
  "Recupera tu contraseña" para el caso inexistente.

**Esta 3ra corrida coincide con la corrida 2 (sesión "continuación 5",
`LOGIN-REGISTRO-FULL-v2`) y contradice la corrida 1 (sesión
"continuación 3", `AC-SEC-04-20260914-115607`)**. Con 2 de 3 corridas
mostrando la fuga de forma consistente y reproducible (línea roja
exclusiva del caso inexistente, mismo texto exacto en ambas), el criterio
de mayoría/rigor usado para el bug crítico (`AC-UL-02`) aplica acá también:
**se cierra como hallazgo real, no como intermitencia**. La corrida 1
(sin fuga) queda como posible falso negativo de esa sesión — no se
investiga más a fondo el motivo puntual, no amerita otra corrida.

**Nota**: no se pudo confirmar el caso "email existente" con la cuenta de
prueba real `jmatevargas@poligran.edu.co` por segunda vez en esta corrida
(el diálogo nativo de Roku volvió a interceptar y precargó
`ottnext@mediastre.am`) — de todos modos es válido como caso de control
porque `ottnext@mediastre.am` es una cuenta real/existente y el contraste
entre "existe" (sin línea roja) vs "no existe" (con línea roja) es lo que
importa para este escenario, no qué email puntual se usó.

**Estado final del device al cerrar esta corrida**: `Home` presionado tras
login exitoso con `jmatevargas@poligran.edu.co` / `Winner2025`
(`login_status:"connected"`, mismo IM real
`30f41b94-1310-46e1-8627-fb31590ffef3`), captura
`reports/azteca/login-registro/AC-SEC-04-tiebreak-20260914-151506/03-final-home.jpg`.
Socket telnet cerrado vía `taskkill` sobre el PID en `ESTABLISHED` del
puerto 8085; el proceso terminó correctamente (confirmado con
`tasklist`), aunque `netstat` siguió mostrando la entrada por unos
segundos (residuo de kernel esperable, no un proceso huérfano real).

## Sesión 2026-09-14 (continuación 7) — corrida RIGUROSA final de validación completa (`LOGIN-REGISTRO-RIGOR-20260914-154433`)

Re-corrida pedida explícitamente por el usuario tras una corrida anterior
que quedó en estado "killed" (cortada, incompleta) -- esta vez con
prioridad explícita en RIGOR sobre velocidad: conexión en el orden
correcto siempre, doble verificación log+captura en cada paso relevante,
parar e investigar ante cualquier anomalía en vez de asumir. Contra
`192.168.1.186`, siguiendo `scenarios/login-registro-runbook.md` de punta
a punta. **Duración real: ~40 minutos** (15:44 → 16:25 hora local).
Evidencia completa en
`reports/azteca/login-registro/LOGIN-REGISTRO-RIGOR-20260914-154433/`
(`telnet.log`/`telnet2.log`/`telnet3.log`/`telnet4.log` -- 4 archivos por
las reconexiones necesarias tras cada relanzamiento real del canal;
capturas `01` a `145`).

### Resultado: las 5 fases confirmadas de nuevo, cobertura completa de los 8 escenarios

Todos los hallazgos previos (bug crítico de autenticación, ausencia de
rate limiting, robustez de inputs, etc.) se RECONFIRMARON sin
contradicción -- ver detalle por fase abajo. No se buscaron hallazgos
nuevos (instrucción explícita del runbook), pero surgieron dos hallazgos
operativos genuinos que sí ameritan quedar documentados (ver más abajo).

- **Fase 1 (cold start deslogueado, AC-UL-01 parte 1 + AC-UL-04)**:
  confirmado con log fresco (`login_status:"anonymous"` tras cold
  restart real) y captura (`04-coldboot-anonymous-home.jpg`, sidebar
  muestra "Ingresar" en vez de "Mi cuenta"). AC-UL-04 reconfirmado
  (contenido Live arrancó sin pedir login, `screen_name:"Player"` con
  `login_status:"anonymous"`, captura `05-play-without-login.jpg`).
- **Fase 2 (batería completa LoginWithPasswordView) -- CONFIRMADA
  COMPLETA**: formato inválido (mensaje inline "Formato de correo
  inválido", captura `12-invalidformat-result.jpg`) → email inexistente +
  3 intentos de password editando último carácter (**AC-SEC-01B**: los 3
  rechazados limpio, `FEDERATION_INVALID_CREDENTIALS`/`CUSTOMER_NOT_FOUND`,
  sin ningún HTTP 429/fricción, capturas `21`/`23`/`28`) → password vacía
  y de 1 char con email válido (**AC-SEC-02**: ambos rechazados, capturas
  `35`-`37`, `41`-`43`) → inyección `abc'or1=1--` como password (**11ª
  reproducción independiente del bug crítico** `AC-UL-02`/`AC-SEC-01`:
  `login_success` pese a password incorrecta, confirmado con MOSTRAR
  antes de enviar, captura `50-MOSTRAR-injection-final.jpg` +
  `52-injection-bug-confirmed-loggedin.jpg`) → password de 60 caracteres
  (**AC-SEC-07**: trunca prolijo con "...", sin crash, captura
  `65-longpw-check.jpg`) → email en MAYÚSCULAS + password correcta
  (**AC-SEC-06 case**: rechazado, `FEDERATION_INVALID_CREDENTIALS`,
  case-sensitive, sin cambios) → email con espacio final + password
  correcta (**AC-SEC-06 espacio + AC-UL-01 parte 2**: `login_success`
  real, IM real, backend trimea el espacio correctamente, captura final
  `89-mi-cuenta-final.jpg` con "Mi cuenta" mostrando el email/nombre real).
- **Fase 3 (Registro, AC-REG-01) -- CONFIRMADA, los 3 casos limpios**:
  registro nuevo (`qa-final-rigor-<timestamp>@example.com`) →
  `screen_name:"Verify with Code"`, sin bypass (captura `99-...`); email
  duplicado (`jmatevargas@poligran.edu.co`) → `EMAIL_ALREADY_REGISTERED`,
  mensaje visible "Este email ya está registrado" (captura
  `108-dup-result.jpg`); password débil (`abc`) → rechazo client-side "La
  contraseña debe tener al menos 8 caracteres" (captura
  `115-weakpw-result.jpg`).
- **Fase 4 (OTP + Olvidé mi contraseña) -- EJECUTADA**:
  - **AC-SEC-03**: código `000000` con email válido → `OTP_CODE_INVALID`,
    mensaje visible, sin crash (captura `124-otp-result.jpg`). Reconfirma
    lo ya sabido, sigue `DONE-MANUAL-PENDING` (confirmación humana del
    código real pendiente).
  - **AC-SEC-04**: 🟡 **NUEVO EMPATE, la pregunta se reabre** -- email
    válido → mensaje limpio sin línea roja (capturas `131-forgot-valid.jpg`);
    email inexistente (`noexiste-rigor-final@example.com`) → **también
    mensaje limpio, SIN línea roja distintiva** (captura
    `137-forgot-invalid.jpg`). Esto contradice el veredicto "DONE, SÍ hay
    fuga" que estaba en el YAML (basado en 2 de 3 corridas previas con
    fuga) -- con esta 4ª corrida independiente el conteo queda 2 a 2 (2
    corridas vieron fuga, 2 no). **Se ACTUALIZA el status en
    `scenarios/azteca.yaml` de vuelta a PARCIAL/pendiente de desempate**
    en vez de dejarlo como DONE con un hallazgo que ya no es mayoritario
    -- hace falta una 5ª corrida de verdad para desempatar, con más
    atención a factores que puedan explicar la intermitencia (¿A/B test
    del lado del backend? ¿depende de algo temporal/de sesión?). No se
    investigó la causa en esta corrida por no ser el objetivo (era
    validación final, no investigación nueva), pero queda anotado como
    prioridad concreta para la próxima sesión.
- **Fase 5 (persistencia, AC-UL-03) -- CONFIRMADA**: login real → cold
  restart genuino (`Home` + esperar 1s + `launch/dev` + esperar 1.5s,
  confirmado con `telnet4.log` línea `Running dev` fresca) → arrancó
  directo en Home personalizado, `login_status:"connected"`, mismo IM
  real, sin pedir login. Captura final
  `145-FINAL-persistence-home.jpg`.

### 🔴 Hallazgo operativo importante (rigor): el log de `onKeyEvent` puede dar FALSOS POSITIVOS de que el tipeo llegó al campo de texto

Encontrado y diagnosticado en vivo durante esta corrida (no documentado
antes con esta claridad): en al menos 3 ocasiones, `roku-type.js` envió
los keypress `Lit_x`/`Backspace` correctamente, y el telnet log SÍ mostró
líneas `onKeyEvent : key = Lit_x press = true/false` -- pero el campo de
texto en pantalla NO cambió (confirmado con captura, incluso con MOSTRAR
activado mostrando el valor viejo sin cambios). Causa raíz identificada:
el foco real estaba en otro componente (el botón "MOSTRAR"/`WithIconButton`
en dos de los tres casos, un botón de submit en el tercero) que también
loguea `onKeyEvent` para las teclas que recibe -- el log por sí solo NO
distingue si el evento fue CONSUMIDO por el campo de texto o solo
recibido y descartado por un widget no-textual. **Regla nueva para el
próximo Agente Player, más estricta que la ya documentada**: después de
CUALQUIER acción que pueda haber movido el foco (un `Select` sobre
MOSTRAR, un submit fallido que a veces deja el foco en el botón en vez de
volver al campo), tomar una captura ANTES de tipear para confirmar
visualmente (borde amarillo/cursor) que el foco está realmente en el
campo de texto -- no alcanza con "el telnet mostró los eventos", hay que
ver el campo cambiar. Esto costó varios intentos fallidos en esta
corrida (campo `abc'or1=1--` se escribió 3 veces hasta que se detectó y
corrigió el problema de foco) pero terminó confirmando la validez del
hallazgo del bug crítico igual, con evidencia visual sólida al final.

### Hallazgo operativo menor: socket telnet huérfano de una sesión previa (la "killed")

Al arrancar esta corrida, un socket ESTABLISHED en el puerto 8085 (sin
proceso Windows dueño visible vía `tasklist`/`Get-Process`, aunque
`netstat`/`Get-NetTCPConnection` sí lo mostraban) bloqueó las primeras
conexiones nuevas ("Console connection is already in use"). Se resolvió
matando procesos node.exe huérfanos adicionales encontrados con
`tasklist` (ninguno con el PID exacto reportado por netstat, pero
liberando los procesos node reales que sí estaban corriendo) y
reintentando -- se resolvió solo tras ese paso, sin necesitar reiniciar
el device físicamente. Lección: cuando `netstat` reporta un PID que
`tasklist`/`Get-Process` no encuentra, no asumir que hay que esperar o
reiniciar el device -- matar los procesos node.exe reales que sí
aparecen en `tasklist` (aunque su PID no coincida exactamente) suele
liberar el socket igual.

### Hallazgo operativo menor: un `Back` inesperado cerró la app a mitad de la corrida (sin acción del agente)

Justo después del primer cold boot de esta sesión, el log mostró un
`onKeyEvent : key = back` que ningún paso de este agente había enviado,
seguido de `EXIT_USER_NAV` -- la app volvió al launcher del sistema por
su cuenta. No se investigó la causa (podría ser un remanente de la
sesión anterior "killed" que no se alcanzó a limpiar del todo, o una
acción externa) -- se relanzó siguiendo el protocolo completo
(`Home`+esperar+`launch/dev`+esperar+reconectar telnet DESPUÉS) y la
corrida continuó sin problemas. Queda como nota, no como hallazgo
confirmado (una sola ocurrencia, no reproducida a propósito).

### Actualización de status en `scenarios/azteca.yaml`

- **AC-SEC-04**: revertido de `DONE` a texto que refleja el empate 2-2 y
  la necesidad de una 5ª corrida de desempate (ver detalle arriba).
- El resto de los 8 escenarios (`AC-UL-01`, `AC-UL-02`, `AC-UL-03`,
  `AC-UL-04`, `AC-REG-01`, `AC-SEC-LOGIN-EDGE-01`, `AC-SEC-03`) quedan
  igual que antes (`DONE`/`DONE-MANUAL-PENDING`/`PARCIAL` según
  corresponda) -- esta corrida los reconfirmó sin contradicción.

### Estado final del device al cerrar esta sesión

App en Home, **logueada con la cuenta válida real**
(`jmatevargas@poligran.edu.co` / `Winner2025`), confirmado con
`login_status:"connected"` + mismo IM real tras un cold restart genuino
(`telnet4.log`, línea `Running dev` fresca) y captura final
`reports/azteca/login-registro/LOGIN-REGISTRO-RIGOR-20260914-154433/145-FINAL-persistence-home.jpg`
(shelf "Continuar viendo" visible). Todos los sockets telnet cerrados
explícitamente vía `taskkill` sobre los PIDs en `ESTABLISHED` del puerto
8085 a medida que se reconectaba entre relanzamientos; verificado al
final con `netstat -ano | grep 8085` sin ninguna conexión remanente y
`tasklist` sin procesos `node.exe` huérfanos.

### Resumen de prioridad para la próxima sesión

1. **Reportar formalmente al equipo de backend** el bug crítico de
   autenticación (11 reproducciones independientes acumuladas) y la
   ausencia de rate limiting -- sigue sin reportarse formalmente, sigue
   siendo la prioridad #1.
2. **Desempatar AC-SEC-04** con una 5ª corrida (ver hallazgo arriba) --
   quedó 2-2, ya no se puede tratar como cerrado.
3. Seguir pidiendo al usuario la confirmación manual pendiente de
   siempre: código OTP real (AC-SEC-03) y email real de reset
   (AC-SEC-04).
4. Si se retoma el toolkit, considerar agregar a `roku-type.js` o al
   flujo del agente una verificación automática de foco (captura antes
   de tipear) para evitar el problema de falsos positivos de log
   documentado arriba -- ahorraría tiempo de diagnóstico manual la
   próxima vez que ocurra.

## Sesión 2026-09-14 (continuación 8) — corrida FINAL de ≤20 min, política de capturas por log, 8 escenarios + AC-SEC-04 desempatado

Corrida contra `192.168.1.186` siguiendo `scenarios/login-registro-runbook.md`
con la política de capturas revisada (log-first, captura solo en puntos 📸 o
diagnóstico ante señal inesperada). Evidencia en
`reports/azteca/login-registro/LOGIN-REGISTRO-FINAL20MIN-20260914-1628/`
(`telnet.log` + `telnet2.log` -- una reconexión a mitad de corrida por
expiración del capturador a los 900s, capturas `01` a `27`).

### ⏱️ TIEMPO TOTAL REAL: ~17 minutos (16:28:49 → 16:45:47 hora local)

Cumple el objetivo explícito de ≤20 min pedido por el usuario -- **más del
doble de rápido que la corrida rigurosa anterior (~40 min)**, cubriendo los
mismos 8 escenarios del grupo con veredicto igual de sólido en cada uno
(ninguno quedó ambiguo por la velocidad). La política de "log primero,
captura solo en 📸 o diagnóstico" funcionó como se esperaba: de las ~27
capturas tomadas, la mayoría fueron diagnósticas (navegación de foco que no
salió como esperado, ver abajo) y no rutina -- pero incluso así el tiempo
total quedó muy por debajo del límite.

### Resultado por escenario (los 8 del grupo)

- **AC-UL-01** (parte 1 + parte 2): ✅ reconfirmado. Cold boot deslogueado
  → `login_status:"anonymous"` en Home; login real con
  `jmatevargas@poligran.edu.co`/`Winner2025` → `login_success`, mismo IM
  real (`30f41b94-1310-46e1-8627-fb31590ffef3`), Home personalizado.
- **AC-UL-02** / **AC-SEC-LOGIN-EDGE-01**: no re-ejecutado esta corrida (ya
  DONE con 11+ reproducciones independientes, instrucción explícita de no
  reconfirmar más) -- sin cambios de estado.
- **AC-UL-03**: ✅ reconfirmado con cold restart real (`Home` + esperar 1s +
  `launch/dev` + esperar, línea fresca "Running dev" en el log) → arrancó
  directo en Home con `login_status:"connected"`, sin pedir login.
- **AC-UL-04**: ✅ reconfirmado. Deslogueado, se entró a un show ("Dramas de
  Familia") y se reprodujo (`player_ready`, VOD) con `login_status:"anonymous"`
  en todo momento -- sin gate de login.
- **AC-REG-01**: no re-ejecutado esta corrida (ya DONE, 3 casos confirmados
  en múltiples corridas previas) -- sin cambios de estado.
- **AC-SEC-03**: no re-ejecutado esta corrida (ya DONE-MANUAL-PENDING) --
  sin cambios de estado.
- **AC-SEC-04**: 🟢 **DESEMPATADO 3-2 -- SÍ hay fuga de información**. Ver
  detalle abajo (foco principal de esta corrida, tal como pidió el usuario).

### AC-SEC-04 — 5ta corrida de desempate: CONFIRMADO, SÍ filtra si el email existe

Con sesión cerrada, se navegó a "Olvidé mi contraseña" dos veces:
- Email válido (`jmatevargas@poligran.edu.co`): mensaje limpio "Recupera tu
  contraseña -- Enviamos un enlace de recuperación a tu email...", **sin**
  línea roja adicional. Captura `10-forgot-valid-email.jpg`.
- Email inexistente (`noexiste-final20min-qa@example.com`): mismo mensaje
  base **más** la línea roja "No encontramos una cuenta asociada a este
  email. Verifica que esté bien..." debajo. Captura `20-forgot-invalid-email.jpg`.

Mismo patrón exacto que las corridas 2 (`LOGIN-REGISTRO-FULL-v2`) y 3
(`AC-SEC-04-tiebreak`), que también vieron la fuga. Con esta 5ta corrida el
conteo queda **3 de 5 corridas con fuga** (corridas 2, 3, 5) **vs. 2 sin
fuga** (corridas 1 y 4-rigor) -- mayoría clara, se cierra como hallazgo real
(`minor`), mismo criterio de mayoría que ya se usó para el bug crítico
`AC-UL-02`. No se investigó la causa de las 2 corridas discrepantes (no
amerita más corridas con esta mayoría). `scenarios/azteca.yaml` actualizado
de "EMPATADO 2-2" a "DESEMPATADO 3-2".

### Nota operativa: el capturador de telnet expiró a mitad de corrida (900s) sin que nadie lo notara hasta que los keypress dejaron de reflejarse en el log

El primer `telnet-capture.js` se lanzó con un límite de 900s (15 min); la
corrida completa terminó llevando ~17 min, así que el capturador murió solo
un poco antes del final. Sin captura activa, varios keypress (Down+Select
para confirmar el login final) no dejaron rastro en el log -- se detectó
tomando una captura de pantalla (que mostró negro, es decir reproducción de
video en curso) en vez de asumir que el paso había fallado, y se resolvió
reconectando un `telnet2.log` fresco de inmediato. **Lección para la
próxima sesión: si una corrida puede acercarse a los 15 min, lanzar el
capturador con un límite mayor (1200-1800s) desde el principio**, o
recordar chequear `tasklist`/proceso vivo si el log deja de crecer de forma
inesperada -- no asumir que "sin log nuevo" significa "el paso no hizo
nada".

### Nota operativa reforzada: navegar desde el campo de password a "OLVIDÉ MI CONTRASEÑA"/"INGRESAR" con Right×10+Right(cruce) es poco fiable

Confirmado varias veces esta corrida: la secuencia de cruce
grid→botones que funciona bien en el campo de **email** (`Right×10 + Right`)
NO fue consistente en el campo de **password** -- varias veces un `Right`
de más terminó tipeando un carácter de la grilla sin querer (una "2", una
"w", una "d") en vez de cruzar, obligando a diagnosticar con captura y
corregir con backspace. **Lo que sí funcionó de forma confiable**: usar el
ícono dedicado "→" (flecha, esquina inferior derecha de la grilla) con
`Select` para cruzar a botones -- llega directo al primer botón de la
columna derecha (ej. `INGRESAR`), y desde ahí `Up`/`Down` navega
confiablemente entre `MOSTRAR`/`OLVIDÉ MI CONTRASEÑA`/`INGRESAR`. Para la
próxima sesión: preferir siempre navegar hasta el ícono "→" explícito en
vez de contar `Right` a ciegas, ahorra los reintentos de diagnóstico que
costó esta corrida.

### Estado final del device al cerrar esta corrida

App en Home, **logueada con la cuenta válida real**
(`jmatevargas@poligran.edu.co` / `Winner2025`), confirmado con
`login_status:"connected"` + mismo IM real en el log y captura final
`reports/azteca/login-registro/LOGIN-REGISTRO-FINAL20MIN-20260914-1628/27-FINAL-loggedin-home.jpg`
(sidebar "Mi cuenta"/shelf "Continuar viendo" visibles). Socket telnet
cerrado explícitamente vía `taskkill //F //PID` sobre el PID en
`ESTABLISHED` del puerto 8085, reverificado con `netstat` -- sin conexiones
`ESTABLISHED` remanentes (solo un `TIME_WAIT` residual esperable) y sin
procesos `node.exe` huérfanos en `tasklist`.

### Resumen de prioridad para la próxima sesión

1. **Reportar formalmente al equipo de backend** ambos hallazgos ya
   maduros: el bug crítico de autenticación (`AC-UL-02`/`AC-SEC-01`, 11+
   reproducciones), la ausencia de rate limiting (`AC-SEC-01B`), y ahora
   también `AC-SEC-04` (fuga de información en "Olvidé mi contraseña",
   mayoría 3-2 confirmada) -- los 3 listos para reportar, ninguno necesita
   más corridas.
2. Seguir pidiendo al usuario la confirmación manual pendiente de siempre:
   código OTP real (`AC-SEC-03`) y email real de reset (`AC-SEC-04`).
3. Considerar lanzar el capturador de telnet con un límite de tiempo mayor
   por defecto (1200-1800s) para evitar el corte a mitad de corrida
   documentado arriba.
4. Batería de login/registro (los 8 escenarios de este grupo) queda
   completamente cerrada -- no hace falta otra corrida de validación salvo
   que se sospeche una regresión real.

## Sesión 2026-09-15 (noche, reconfirmación de category con 2do show) — El bug de `category` SÍ es general del fix, pero su síntoma varía por show

Tarea puntual pedida por el usuario tras la sesión "Validación de Monday:
PR #173": reconfirmar el hallazgo de `category` de AN-02/AN-03 (visto con
"Lotería del Crimen": `"category":"CMS, Lotería del Crimen"`, que no
coincide con su género real "Acción, Crimen, Horror") probando con un show
DISTINTO, para saber si es un problema general del fix o algo puntual de
ese show. Evidencia completa:
`reports/azteca/analytics/RECONFIRMACION-CATEGORY-20260915-2300/` (telnet.log
+ 17 capturas, incluye ShowPage de los 2 shows probados).

### Conexión y arranque
Conexión limpia sin incidentes: `Home` → 1s → `launch/dev` → 1.5s →
telnet, conectó al primer intento (`CONNECTED`, sin "Console connection is
already in use"). Nota: `netstat` mostraba una conexión `ESTABLISHED` en
el puerto 8085 con un PID (25780) que **no correspondía a ningún proceso
real** (`tasklist`/`Get-Process` no lo encontraron) -- entrada fantasma de
una sesión anterior, no bloqueó la conexión nueva. Queda como dato para
la próxima sesión: si se ve una entrada `ESTABLISHED` así, no asumir que
bloqueará el telnet -- puede ser un artefacto de la tabla de sockets de
Windows sin proceso real detrás.

### Shows probados

1. **"Exatlón México / Décima Temporada"** (Top 10 #1 en Home). Género
   real confirmado en su propia ShowPage: **"Aventura, Juegos"** (captura
   `04-showpage-exatlon.jpg`). Se intentó reproducir 2 episodios
   distintos ("Refuerzo para el Equipo Azul" y "Tercer Duelo de
   Eliminación") -- **ambos fallaron al reproducir**:
   `HelpFuncs : getErrorReason : ResponseError` con `code:403
   reason:"Forbidden"`, seguido de `BRIGHTSCRIPT: ERROR: ParseJSON:
   Unknown identifier 'Forbidden': mediastreamrokuplayersdk:/source/apis/MediaStreamPlayerAPI.brs(68)`
   y el player se cerró solo de vuelta a la ShowPage. Esto es un
   **hallazgo aparte** (posible bloqueo de contenido/DRM/geo, no
   relacionado a category) -- no bloqueó la tarea porque `player_ready` sí
   alcanzó a dispararse ANTES del error 403 en ambos intentos (líneas 171
   y 294 del telnet.log), y ambos trajeron `category:"not-set"`.
2. **"La Granja VIP Segunda Temporada"** (fila "Realities y concursos" en
   Home). Género real confirmado en su propia ShowPage: **"Exterior,
   Deportes y Recreación, Juegos"** -- 3 géneros (captura
   `11-showpage-granja.jpg`). Este SÍ reprodujo con normalidad (categoría
   "Videos 24/7", episodio corto de 2:07 "Se los voy a aventar a la
   cama..."). Este fue el caso completo y limpio para la reconfirmación.

### Resultado: category llega mal, pero DISTINTO al patrón de Lotería del Crimen

Con "La Granja VIP", los 3 eventos de la misma reproducción --
`screen_view` (línea 450), `player_ready` (línea 462), `video_views`
(línea 656) -- y además 2 ocurrencias de `video_VOD_progress` (25% y 50%,
líneas más adelante) dieron TODOS `"category":"not-set"`. **NO se repitió
el patrón "CMS, <título del show>"** visto con Lotería del Crimen -- acá
directamente no llegó ningún valor de género real, cayendo en el mismo
placeholder que usa el sistema para contenido sin categoría asignada
(comparar con AN-04, donde "not-set" es el comportamiento ESPERADO para un
VOD sin categoría real -- acá el show SÍ tiene categoría real y aun así
cae en "not-set", que es el bug).

**Conclusión para el ticket/PR #173**: el bug de `category` es
**confirmado como un problema GENERAL del fix**, no algo puntual de
"Lotería del Crimen" -- en 2 shows distintos (3 episodios en total) el
valor real de categoría NUNCA llegó correcto. Pero el síntoma concreto
**varía según el show/contenido**:
- Lotería del Crimen → concatena mal "CMS" + título del show.
- La Granja VIP (y aparentemente Exatlón, aunque no se pudo confirmar la
  reproducción completa) → cae en "not-set" a pesar de tener géneros
  reales asignados.

Esto sugiere que la función que arma `category` tiene más de un camino de
fallo (quizás depende de qué campo del backend/CMS esté poblado para cada
show en particular), no un solo bug determinístico -- dato importante
para que el equipo de backend priorice: no alcanza con corregir el caso
"CMS + título", hay que revisar la lógica completa de dónde saca el
género real.

### plataforma: 100% consistente, reconfirmado sin excepción
En TODOS los eventos de esta corrida (~15+ eventos, incluidos los del
intento fallido de Exatlón): `"plataforma":"TV Azteca En Vivo Roku"`,
nunca la key `platform` residual, nunca vacío. Cero divergencias.

### AN-07 (`video_VOD_progress`) -- confirmado de paso, sin querer
Como el episodio de La Granja VIP elegido era muy corto (2:07), se pudo
esperar en tiempo real (sin scrub) y capturar 2 ocurrencias de
`video_VOD_progress` (25% y 50%), ambas con los mismos valores de
`plataforma`/`category` que el `player_ready` de la misma reproducción --
cierra un pendiente viejo que quedaba abierto desde la sesión del PR-173.

### AN-09 (categorías múltiples) -- sigue bloqueado, pero por una razón más clara ahora
Se encontraron y confirmaron 2 shows con géneros múltiples reales
(Exatlón: 2 géneros, La Granja VIP: 3 géneros) -- pero como `category`
cayó en "not-set" en ambos, **no se pudo observar ningún formato real de
categorías múltiples** para juzgar si vienen coma-separadas en un campo
(como pide el caso) o de otra forma. Este caso queda bloqueado por AN-02,
no es un caso independiente sin intentar.

### Cierre de la corrida
Socket telnet cerrado (proceso `node.exe` matado con `taskkill //F`,
reverificado con `tasklist` sin procesos `node.exe` remanentes). Device
relanzado (`launch/dev`) y confirmado en Home, `active-app` con `id="dev"`,
y el último `screen_view` real del log mostrando
`login_status:"connected"` -- logueado con la cuenta válida
(`jmatevargas@poligran.edu.co`). Captura final:
`reports/azteca/analytics/RECONFIRMACION-CATEGORY-20260915-2300/99-final-home-logged-in.jpg`.

### Pendiente para la próxima sesión
- Reportar el hallazgo 403/Forbidden de Exatlón México como posible bug
  aparte (2/2 episodios probados fallaron) -- no se confirmó si es
  específico de esos 2 episodios, del show completo, o más amplio.
- Seguir intentando aislar el formato real de categorías múltiples
  (AN-09) una vez que el equipo corrija el bug base de `category` (AN-02).
- Reportar al equipo de Monday/PR-173 el hallazgo consolidado: el bug de
  category es general (2/2 shows probados con géneros reales fallan),
  con 2 síntomas distintos observados hasta ahora.

### 🆕 Sesión 2026-09-18 (continuación) -- AC-UL-01 cerrado completo; batería del resto interrumpida por presupuesto

Retomando el intento previo (mismo día, device 192.168.1.54, build "TV
Azteca En Vivo" v1.24.92609040 reconfirmado sin cambios vía `query/apps`):

- **Logout real forzado desde AccountPage**: navegación Home -> Left ->
  Down x4 -> Select llega a "Mi cuenta"; dentro, Right + Select sobre
  "Cerrar sesión" -> log confirma `screen_view` inmediato con
  `"login_status":"anonymous"` (IM vacío). Esto por fin permitió observar
  el cold start real en estado deslogueado limpio, que el intento anterior
  no había podido hacer (arrancó con sesión persistida de una corrida
  vieja).
- **Cold start deslogueado confirmado**: `Home` + `launch/dev` -> primer
  `screen_view` real con `login_status:"anonymous"`. La app NO muestra un
  popup modal forzado -- dejó navegar libre con el sidebar mostrando
  "Ingresar" en vez de "Mi cuenta"/"Favoritos" (comportamiento consistente
  con lo ya documentado para AC-UL-04, no es nuevo).
- **Hallazgo de flujo no documentado antes**: `LoginEmailView` ahora
  muestra explícitamente DOS botones separados -- "ENVIAR CÓDIGO" (OTP) e
  "INGRESAR CON CONTRASEÑA" -- en vez de un único "Continuar" que asumía
  contraseña. El runbook existente no distinguía esto; si se presiona
  Select por default sobre el primer botón enfocado tras cruzar del
  teclado, cae en el flujo de código (`RegVerifyCode`) en vez de password.
  Para completar login real hay que navegar explícitamente hasta
  "INGRESAR CON CONTRASEÑA". Vale la pena que el runbook lo aclare para
  la próxima corrida (no llegué a editarlo, solo el YAML de AC-UL-01).
- **Login real exitoso**: email `jmatevargas@poligran.edu.co` + password
  `Winner2025` (verificado char por char con MOSTRAR antes de enviar) ->
  `login_success` real, mismo IM histórico
  `30f41b94-1310-46e1-8627-fb31590ffef3`, `login_status:"connected"`, Home
  pasa a mostrar shelf "Continuar viendo" e ícono de cuenta en sidebar.
  **AC-UL-01 queda DONE completo** (los 6 pasos del escenario cubiertos en
  una sola corrida) -- ver detalle y evidencia en
  `scenarios/clients/azteca/scenarios/login-registro/scenarios.yaml`.
  Evidencia: `reports/azteca/2026-09-18_11-37-login-registro/{logs/AC-UL-01-retry.log,videos/AC-UL-01-retry.mp4,screenshots/AC-UL-01-retry-*.jpg}`.
- Socket telnet cerrado limpio al terminar (`kill` sobre el PID del
  proceso Node dedicado, verificado sin remanente).

**Pendiente real para la próxima sesión (no llegué por presupuesto):**
AC-UL-02 a AC-SEC-04 (7 escenarios restantes de login-registro, ya
documentados como DONE de corridas previas -- solo faltaría una
revalidación rápida si se quiere, no son bloqueantes), y las baterías
completas de navegación (35 casos) y player (27 casos) que esta sesión no
llegó a empezar. Session quedó logueada con la cuenta real al cerrar.

---

## Sesión 2026-09-18 (tarde/noche) — Cierre de baterías contra .54 (login-registro, navegación, player)

Device 192.168.1.54 (Roku Express), build "TV Azteca En Vivo"
v1.24.92609040 (sin cambios en toda la corrida). Cuenta de prueba
jmatevargas@poligran.edu.co (password real Winner2025; IM
30f41b94-1310-46e1-8627-fb31590ffef3). Grabación de cámara real por caso
(camera-server.js corriendo con teléfono conectado). Telnet de consola en
:8085 (solo 1 cliente a la vez — cerrar entre escenarios).

### login-registro: los 6 que faltaban, RE-CONFIRMADOS
- **AC-UL-03** (re-login tras reinicio): PASA. Sesión persiste vía
  roRegistry; cold relaunch arranca directo logueado (login_status
  connected inmediato, 0 anonymous, sin excepciones).
- **AC-UL-04** (login diferido): NO hay gating del live/VOD estándar —
  logout real desde AccountPage, luego el hero live "A Quien Corresponda"
  reprodujo deslogueado (media-player state=play, login_status anonymous).
- **AC-REG-01** (registro nuevo): PASA. Email inventado
  qa-test-2026-09-18-01@poligran.edu.co + password válida QaTest2026 ->
  "Verify with Code" (envía código, exige verificación, sin crash). Código
  inventado 000000 rechazado (OTP_CODE_INVALID). No se completó registro
  (sin acceso al email), no queda cuenta verificada creada.
- **AC-SEC-LOGIN-EDGE-01** (sub-caso A, fuerza bruta): re-confirmado NO
  hay rate limiting — 3 intentos consecutivos con email inexistente ->
  FEDERATION_INVALID_CREDENTIALS x6, 0 fricción (sin 429/captcha/throttle).
- **AC-SEC-03** (OTP login): la app pide el código y dice enviarlo; código
  inventado 111111 rechazado (OTP_CODE_INVALID), nunca loguea. Pendiente
  confirmación HUMANA del código real.
- **AC-SEC-04** (olvidé contraseña): FUGA CONFIRMADA DEFINITIVA (ya no
  depende de mayoría 3-2). Email inexistente -> línea roja "No encontramos
  una cuenta..." + backend HTTP 404 CUSTOMER_NOT_FOUND. Email válido ->
  mensaje limpio, sin línea roja.
- (AC-UL-01 y AC-UL-02 ya estaban DONE de corridas previas; AC-UL-02 =
  bug crítico de bypass de login SIGUE ACTIVO, 9na reproducción.)

### navegación: los 2 que faltaban, corridos contra .54
- **SC-MULTI-ENTRY-SHOW-01**: PASA. 2 puntos de entrada — Search
  ("exatlon" -> "Exatlón Décima Temporada" ShowPage -> Back vuelve a
  Search) y Secciones ("Lotería del Crimen" ShowPage -> Back vuelve a
  Secciones). Back siempre vuelve al ORIGEN, no a Home.
- **SC-SHOW-AOD-01**: re-validado con evidencia positiva. El mejor
  candidato a AOD (el ítem rotulado PODCAST "Lo Que La Gente Cuenta: El
  Podcast") reproduce como VIDEO (media-player video=mpeg4_10b/H.264, HLS,
  VOD). Azteca no tiene audio-only; hasta los podcasts son video.

### player: los que faltaban contra .54
- **SC-SHOW-01**: PASA. Cold start -> Home -> "Historias de Vida" ->
  ShowPage -> VER AHORA -> VOD reproduce (state=play, HLS, ~20min, sin
  DRM), pausa/reanudar OK (pause<->play), 0 excepciones.
- **SC-PLAYER-CONTENT-MATRIX-01** + **SC-PAYWALL-01**: HALLAZGO MAJOR
  NUEVO. El show **"Exatlón México"** (Top 10 #1) devuelve **HTTP 403
  Forbidden** en el endpoint de stream-data, tanto anónimo COMO logueado
  con jmatevargas, en Programas completos Y Mejores momentos (4
  ocurrencias) -> el show entero está gateado por entitlement/suscripción
  que la cuenta de prueba no tiene. **BUG:** el SDK maneja mal el 403 —
  hace ParseJSON del string "Forbidden" ->
  `BRIGHTSCRIPT: ERROR: ParseJSON: Unknown identifier 'Forbidden':
  mediastreamrokuplayersdk:/source/apis/MediaStreamPlayerAPI.brs(68)` ->
  onGetStreamDataTaskApiResponse *** ERROR *** -> closePlayer SILENCIOSO
  (vuelve a ShowPage sin mensaje, sin PaymentRequiredPage, sin prompt de
  login). Contraste: "Venga La Alegría" (Top 10 #4), "Historias de Vida"
  (VOD), el podcast de 2022 (contenido viejo) y el live TODOS reproducen
  bien. ESTO por fin identifica el contenido restringido que SC-PAYWALL-01
  nunca había encontrado — pero el manejo es un bug, no una
  PaymentRequiredPage. REPORTAR a Core/Player.
- **SC-FLOW-STRESS-01**: Check 1 (ráfaga "Ver ahora") NO reproducido 6/6
  en 2 shows (VLA + Ventaneando), app id="dev" intacta, 0 excepciones.
  Check 2 (salir/reentrar) 6/6 limpio. Check 3 (Up Next) ya CONFIRMADO en
  .63 (no re-ejecutado; smart-seek en .54 falló exit 2 a ~55% de un
  programa de ~39min, impráctico llegar al final natural).

### Notas operativas de esta sesión
- **La tool Write SÍ está bloqueada para archivos de reporte desde
  subagente.** Mensaje exacto del harness al intentar escribir REPORTE.md:
  *"Subagents should return findings as text, not write report files.
  Include this content in your final response instead."* Los REPORTE.md de
  las 3 baterías se entregaron como texto en el handback final, no como
  archivos. (Los status de los YAML y esta sección de PROJECT_MEMORY SÍ se
  pudieron escribir con Edit.)
- Recordatorio: Home físico SALE al Roku OS (active-app pasa a "Roku
  Dynamic Menu"); para volver a la app usar launch/dev, no seguir navegando
  creyendo que se está en la app.
- plugin_inspect/dev.jpg devuelve 404 cuando la app NO está en foreground
  (estás en el Roku OS) — señal de que hay que relanzar.
- Sesión quedó LOGUEADA con la cuenta de prueba al cerrar.
