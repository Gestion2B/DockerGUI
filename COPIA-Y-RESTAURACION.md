# Copia y restauración de app-fotos — paso a paso

Probado: copia desde la GUI, restauración en otro PC (base, uploads, `/api/health`) y web local contra la copia.
**No probado:** recrear el Funnel de Tailscale en un PC nuevo (paso 4 de "Restaurar").

> En los comandos, `D:` es la letra del disco externo y `DESKTOP-0K69BTC` el nombre de la carpeta del servidor
> dentro de `BackupsMonzon`. Cámbialos si son otros.

---

## 1. Hacer la copia (en el servidor)

1. Conecta el disco externo y desbloquéalo con BitLocker.
2. Abre la GUI: <http://127.0.0.1:8780> (si no está abierta, doble clic en `Abrir-GUI-Docker.cmd`).
3. Pestaña **Copia a disco externo**.
4. Proyecto: **Proyecto Fotos (app-fotos)**. Carpeta del disco: `D:\BackupsMonzon`.
5. Pulsa **Copiar el proyecto al disco externo** y escribe `COPIAR`.
6. Espera a que acabe. Debe decir **"copia en buen estado"**.
   - El aviso por las fotos del FTP es normal.
   - Si dice **"HAY PROBLEMAS"**, la copia no vale: revisa la salida y repite.
7. Expulsa el disco con seguridad y guárdalo.

Por consola (alternativa):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\ServerIT\Desktop\Docker-Autoarranque\Consola-Gestor-Docker.ps1" -Action ExternalBackup -Project app-fotos -Destino D:\BackupsMonzon
```

Qué contiene la copia: carpeta del proyecto (con `.env` y claves), el gestor (con `Restaurar-Copia.ps1`),
volcado de la base, portadas y avatares.
**No contiene** las fotos y vídeos del hosting FTP, ni el proyecto Pool.

Actualizar el gestor antes de copiar (si hay cambios en el repositorio):

```powershell
cd C:\Users\ServerIT\Desktop\Docker-Autoarranque
git pull
```

Luego doble clic en `Abrir-GUI-Docker.cmd`.

---

## 2. Restaurar (en un PC nuevo o limpio)

**Requisitos:** Docker Desktop abierto, internet, el disco desbloqueado y **ningún contenedor `monzon_*`**
en ese PC (si los hay, el script se niega: es lo correcto).

### Paso 1 — Comprobar el disco

```powershell
dir D:\BackupsMonzon\DESKTOP-0K69BTC\bases
```

Debe haber un `backup-datos-AAAA-MM-DD_HH-MM-SS.zip` con la fecha esperada.

### Paso 2 — Ver el plan (no cambia nada)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\BackupsMonzon\DESKTOP-0K69BTC\gestor\Restaurar-Copia.ps1" -Origen "D:\BackupsMonzon\DESKTOP-0K69BTC" -DestinoProyecto "C:\Proyectos\app-fotos"
```

Debe terminar con `PLAN (no se ha cambiado nada)`.

### Paso 3 — Restaurar

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\BackupsMonzon\DESKTOP-0K69BTC\gestor\Restaurar-Copia.ps1" -Origen "D:\BackupsMonzon\DESKTOP-0K69BTC" -DestinoProyecto "C:\Proyectos\app-fotos" -Ejecutar
```

Escribe `RESTAURAR` cuando lo pida. Tarda varios minutos la primera vez (construye el backend).
Al final debe mostrar:

- `Contenido: N eventos, N fotos, N usuarios` (compara con producción)
- `Uploads copiados`
- `/api/health responde 200`
- `RESTAURACION TERMINADA.` — si dice `CON N AVISO(S)`, lee los mensajes amarillos.

### Paso 4 — Comprobar la API (solo lee)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Proyectos\app-fotos\probar-restauracion.ps1" -Dni TU_DNI_DE_ADMIN
```

Pide la contraseña por teclado y no la guarda.

### Paso 5 — Acceso desde fuera (solo en una recuperación real)

1. Instala Tailscale e inicia sesión. El PC debe aparecer con el **mismo nombre** que el servidor antiguo
   (`desktop-0k69btc.tail736021.ts.net`); si cambia, las apps ya publicadas apuntarán a una dirección que no existe.
2. Revisa que `gestor\proyectos-produccion.txt` lleve las rutas de este PC (trae las del servidor antiguo).
3. Ejecuta:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\BackupsMonzon\DESKTOP-0K69BTC\gestor\Iniciar-Docker-Produccion-Completo.ps1"
```

---

## 3. Ver la web de la copia (solo para pruebas)

La web del servidor apunta a producción, no a la copia. Para probar la copia hace falta una web compilada
solo para local (`web-local-prueba.zip`, no se sube a Git):

```powershell
docker cp C:\PruebaRestauracion\web-local\. monzon_backend:/app/public
```

```powershell
docker restart monzon_backend
```

Abre <http://localhost:3000/>.

---

## 4. Limpiar una prueba (solo en el PC de prueba, nunca en el servidor)

En la carpeta `produccion` del proyecto restaurado:

```powershell
docker compose --project-name app-fotos down -v
```

Y borra la carpeta de la prueba.

---

## Avisos importantes

- **Las fotos y vídeos están en el hosting FTP** y esta copia no los incluye. Si el hosting se perdiera, no hay copia de ellas
  (haría falta sincronizarlas con WinSCP: `Copia-Externa.ps1 -WinScpSesion "NombreSesion"`).
- **No restaures sobre una producción en marcha:** se pierde lo creado después de la copia. El script se niega por eso.
- **Durante una prueba no borres ni retires fotos y no pulses acciones que avisen por Discord:** el backend restaurado
  usa las credenciales reales del hosting y del canal.
- **La carpeta del disco es solo para esto:** la copia borra en ella lo que ya no existe en origen.
- **La copia lleva contraseñas y datos personales:** disco con BitLocker To Go.
- **Una copia sin probar no es una copia:** repite la restauración en otro equipo de vez en cuando.
