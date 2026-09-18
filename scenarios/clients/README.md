# scenarios/clients/ — un cliente por carpeta

Cada cliente de Mediastream que usa la app OTT sobre Roku (Azteca, y los
que se agreguen después) tiene su propia carpeta acá, con TODO lo que es
específico de ese cliente: su device de QA, su cuenta de prueba, su
catálogo de contenido, y el resultado real de correr cada batería contra
su build.

## Estructura de cada cliente

```
scenarios/clients/<cliente>/
  profile.yaml              # IP del device, feature flags, notas del cliente
  scenarios/
    login-registro/
      scenarios.yaml
      runbook.md             # (si existe) guía manual del área
    navegacion/
      home/scenarios.yaml
      pantallas/scenarios.yaml
      shows/scenarios.yaml
      estres/scenarios.yaml
    player/scenarios.yaml
    analytics/scenarios.yaml
    boot-conectividad/scenarios.yaml
    performance/scenarios.yaml
  catalog.json               # contenido de prueba real (IDs, budgets) --
                              # usado por los scripts de scripts/test-*.ps1
```

## Carpetas especiales (no son clientes reales)

- **`_template/`** — perfil vacío, punto de partida para dar de alta un
  cliente nuevo. Nunca se corre contra un device real.
- **`_reference/`** — la app de referencia del Core ("Next" /
  `OTTNext_CLIENT_APP`), que Mediastream usa quando no hay un build de
  cliente cargado. NO es un cliente que paga por el servicio -- sirve
  como punto de comparación: si un cliente real se comporta distinto de
  lo documentado acá, es señal de que es la personalización de ESE
  cliente la que cambia el comportamiento, no un bug del Core en general.

## Cómo sabe un agente qué batería correr para qué cliente

Antes de correr cualquier batería, confirmar (o preguntar si no está
claro):

1. **¿Contra qué cliente estoy corriendo?** -- mirar qué build/canal está
   cargado en el device real (`query/apps` por ECP, NUNCA asumir) y
   compararlo contra `scenarios/clients/<cliente>/profile.yaml`.
2. Usar las baterías de `scenarios/clients/<ese-cliente>/scenarios/` --
   NO las de otro cliente, aunque los pasos se parezcan (el Core es el
   mismo, pero el contenido/cuentas/feature-flags cambian).
3. Guardar evidencia en `reports/<ese-cliente>/...` (ver
   `reports/README.md` para el formato de carpetas por corrida).
4. Si es la primera vez que se corre una batería para un cliente nuevo,
   usar como base los escenarios de `scenarios/clients/azteca/scenarios/`
   (la batería más completa y validada hoy) o los de `_reference/` si el
   caso puntual solo existe ahí -- pero SIEMPRE re-validar contra el
   device real de ese cliente, nunca asumir que un resultado de otro
   cliente aplica igual.

## Multi-cliente todavía pendiente

Hoy solo existe `azteca/` con contenido real. El modelo ya soporta
agregar clientes nuevos sin tocar nada de lo existente -- cada cliente es
una carpeta aislada. Ver `scenarios/shared/README.md` para el plan a
futuro de extraer plantillas verdaderamente genéricas a medida que se
validen 2+ clientes con el mismo resultado.
