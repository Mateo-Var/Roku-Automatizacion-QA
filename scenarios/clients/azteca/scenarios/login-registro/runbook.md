# Runbook optimizado: batería completa de login/registro en 1 sola corrida

> **Registro consolidado (2026-09-14):** el YAML ya no tiene IDs separados
> para cada variación (AC-SEC-01/01B/02/05/06/07 ni AC-UL-KEYBOARD-01) --
> todo eso vive ahora en un solo `AC-SEC-LOGIN-EDGE-01` con sub-casos A-E.
> Las fases de este runbook siguen aplicando igual (la mecánica de
> ejecución no cambió, solo cómo se registran los resultados) -- cuando
> una fase de abajo dice "cubre AC-SEC-XX", leelo como el sub-caso
> correspondiente de `AC-SEC-LOGIN-EDGE-01`. TODOS los sub-casos ya están
> `DONE` -- esta corrida es de VALIDACIÓN FINAL de que la batería completa
> funciona de punta a punta con el registro ya consolidado, no para buscar
> hallazgos nuevos en ellos.

> Objetivo: cubrir TODOS los escenarios `AC-UL-*`, `AC-REG-01`, `AC-SEC-*`
> del grupo login/registro (ver `scenarios/azteca.yaml` para el detalle de
> `expected`/`logs_watch` de cada uno) en **una sola sesión continua**,
> en **15-20 minutos**, en vez de 14 corridas separadas.
>
> La razón por la que las corridas separadas eran lentas no era el
> chequeo en sí (ya optimizado con `scripts/roku-type.js` + log-first) --
> era volver a navegar desde Home hasta la pantalla de login/password cada
> vez. Este runbook elimina esa repetición: se entra UNA vez a cada
> pantalla relevante y se encadenan ahí todas las variantes que
> correspondan, editando el campo en vez de re-tipeando desde cero.

## Política de capturas (2026-09-14, revisión post-corrida rigurosa)

La corrida rigurosa anterior tardó ~40 min porque tomó captura de
verificación en casi cada paso ("focus-check" repetidos). Eso SÍ atrapó
un problema real (el log de `onKeyEvent` puede dar falso positivo si el
foco estaba en un widget equivocado, ver `PROJECT_MEMORY.md`) pero es
demasiado caro para hacerlo siempre. Regla nueva, para bajar a ≤20 min sin
perder esa protección:

1. **Por defecto, confirmá con LOG, no con captura**, usando estas señales
   (todas gratis/instantáneas):
   - Cambio de pantalla esperado → `screen_name` en el evento de tracking,
     o la línea `<Componente> : Init` del componente al que se supone que
     llegaste (ej. `LoginWithPasswordView : Init`).
   - Texto tipeado → `onKeyEvent : key = Lit_<char> press = false` en la
     secuencia esperada.
   - Resultado de una acción → `login_success`/`login_error`/código de
     error específico.
2. **Tomá captura SOLO cuando:**
   - (a) El paso pide leer algo que el log no puede confirmar por sí solo
     (mensaje de error visible al usuario, contraseña en claro con
     MOSTRAR, resultado final de un caso marcado 📸 en este runbook), o
   - (b) **El log NO muestra la señal esperada** después de una acción
     (ej. tipeaste pero no aparece el `Init` del siguiente componente, o
     la secuencia de `Lit_` no coincide con lo que mandaste) -- ahí la
     captura es DIAGNÓSTICO de que algo salió mal, no rutina.
3. Si una captura de diagnóstico (caso b) confirma que efectivamente algo
   se desvió (foco equivocado, pantalla distinta a la esperada), corregí
   y seguí -- pero no vuelvas a sacar captura "por las dudas" en el
   siguiente paso normal, solo porque el anterior falló.

Con esto, el presupuesto de capturas de toda la corrida debería rondar las
8-12 (los puntos 📸 ya marcados en cada fase, más las eventuales de
diagnóstico), no 145 como en la corrida anterior.

## Regla general para toda la corrida

- `scripts/roku-type.js` para todo tipeo, telnet conectado ANTES.
- Verificación por LOG primero (`Lit_<char> press = false`), captura solo
  en los puntos marcados 📸 abajo.
- NO reconfirmar el bug crítico de `AC-UL-02`/`AC-SEC-01` más allá de lo
  que ya sale solo -- si un paso lo dispara de rebote, anotarlo en una
  línea y seguir, no pararse a re-verificar con MOSTRAR otra vez (ya tiene
  8 reproducciones, sobra evidencia).

## ⚠️ Obstáculo conocido: diálogo nativo de cuenta Roku (one-touch)

Confirmado 2026-09-14: al entrar a "Ingresar con email" desde cero, a
veces intercepta un diálogo NATIVO de Roku (no es de la app Azteca) tipo
"Inicia sesión" con una cuenta Roku ya vinculada (ej. `ottnext@mediastre.am`).
Si aparece: navegar a la opción **"Usar un correo electrónico diferente"**
(o equivalente) para salir de ese diálogo y llegar a la pantalla real de
LoginEmailView de la app. Verificar por log (`screen_name` o `Init` del
componente esperado) que se salió del diálogo nativo antes de seguir
tipeando -- si se tipea directo sin salir de ahí, el texto se pierde o va
a un campo equivocado.

## Fase 1 -- Cold start, deslogueado (cubre AC-UL-01 parte 1, AC-UL-04)

1. `Home` + esperar 1s + `launch/dev` + esperar 1.5s (cold start real).
2. Confirmar por log: aparece prompt/pantalla de login sin sesión → **AC-UL-01 parte 1**.
3. Sin loguear, intentar reproducir 1 contenido (VOD o live desde Home) →
   confirmar si reproduce sin pedir login → **AC-UL-04** (ya se sabe que
   probablemente sí reproduce sin login -- solo confirmar que se sostiene,
   no hace falta explorar más contenido que la vez pasada).

## Fase 2 -- Una sola entrada a LoginWithPasswordView, encadenar TODO ahí (cubre AC-UL-02, AC-SEC-01B, 02, 05, 06, 07, y el login final real)

Entrar UNA vez al flujo "Ingresar con email". A partir de acá, todo pasa
en la misma pantalla, editando campos en vez de volver atrás:

1. **Campo email**, en esta secuencia (editando, no re-navegando):
   - Formato inválido (sin @) → confirmar rechazo/botón bloqueado → **AC-SEC-06 relacionado / AC-UL-02 Caso C (parte email)**
   - Borrar, tipear email inexistente (ej. `no-existe-qa@example.com`) → avanzar a password
2. **Campo password** (con el email inexistente cargado):
   - Password random cualquiera → enviar → confirmar rechazo (`FEDERATION_INVALID_CREDENTIALS` o similar) → **AC-UL-02 Caso A**
   - Editar solo el último caracter, reenviar → confirmar rechazo de nuevo (intento 2/3)
   - Editar de nuevo, reenviar → confirmar rechazo (intento 3/3) → si NINGUNO de los 3 tuvo fricción extra (delay/bloqueo/captcha) → confirma **AC-SEC-01B** (ya se sabe el resultado, solo reconfirmar rápido, sin 📸 salvo algo cambie)
3. Volver al email (via "VOLVER AL INICIO" si hace falta, es la única
   transición de pantalla completa que se repite en esta fase), tipear el
   **email válido** (`qa.tester@example.com`), avanzar a password:
   - Password vacía → enviar → confirmar rechazo → **AC-SEC-02 (vacía)**
   - 1 caracter → enviar → confirmar rechazo → **AC-SEC-02 (1 char)**
   - String de inyección (ej. `abc'or1=1--`) → enviar → va a loguear por
     el bug conocido, eso es esperado, NO es un hallazgo nuevo -- solo
     confirmar que no hubo excepción BrightScript ni crash → **AC-SEC-05 (password)**
   - (nota: esto ya te deja logueado por el bug -- desloguear con
     `AccountPage` → "Cerrar sesión" antes de seguir, rápido, sin captura)
   - Volver a email válido → password: string largo (50+ chars) → enviar
     → confirmar trunca prolijo, sin crash, sin freeze → **AC-SEC-07 (password)**
   - 📸 Activar MOSTRAR + captura acá (único momento de esta fase que
     amerita foto -- confirma visualmente que el campo largo se ve bien)
   - Email en MAYÚSCULAS + password correcta → confirmar si rechaza o
     loguea → **AC-SEC-06 (case)**
   - Email con espacio final + password correcta → confirmar → **AC-SEC-06 (espacio)**
   - Finalmente: email válido + password REAL correcta (`Ex4mpleP4ss!`) →
     login exitoso real → **AC-UL-01 parte 2** (confirmar identidad
     visible) → 📸 captura de "Mi cuenta" con el nombre real (cierre de
     AC-UL-01)

## Fase 3 -- Registro, una sola entrada (cubre AC-REG-01)

Con sesión ya cerrada (logout desde AccountPage, rápido):

1. "Regístrate" → email nuevo de prueba + password de prueba → confirmar
   pantalla de verificación por email (no bypass) → **AC-REG-01 caso 1**
2. Editar el email al ya existente (`qa.tester@example.com`) →
   confirmar rechazo por duplicado → **AC-REG-01 caso 2**
3. Password débil (`abc`) → confirmar rechazo client-side → **AC-REG-01 caso 3**
   📸 una sola captura del mensaje de error final acá alcanza.

## Fase 4 -- OTP y "Olvidé mi contraseña" (cubre AC-SEC-03, AC-SEC-04)

1. "Ingresar con código" con email válido → código inventado (`000000`)
   → confirmar rechazo → **AC-SEC-03** (dejar nota: código real pendiente
   de confirmación del usuario)
2. "Olvidé mi contraseña" con email válido → capturar mensaje. Repetir con
   email inexistente → comparar → **AC-SEC-04** (dejar nota: correo real
   pendiente de confirmación del usuario)

## Fase 5 -- Persistencia tras reinicio (cubre AC-UL-03)

1. Loguear de nuevo con la cuenta real (si no quedó logueada).
2. `Home` + `launch/dev` (cold restart) → confirmar que arranca directo
   logueado, sin pedir login de nuevo → **AC-UL-03**.
3. 📸 captura final: Home logueado, cierre de la corrida completa.

## Presupuesto de capturas para toda la corrida: ~4-5 en total

(vs. las 25-50 por escenario de las corridas anteriores) -- esto es lo que
más va a bajar el tiempo, junto con no repetir la navegación Home→Login
14 veces.
