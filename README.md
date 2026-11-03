# DockerGUI

Gestor Docker-Autoarranque: panel local (GUI), consola y scripts para actualizar proyectos Docker,
hacer copias de sus bases de datos y **copiar/restaurar un proyecto completo en un disco externo**.

- `Gui-Docker/` API Node (contenedor `docker-updater-api`, 127.0.0.1:8780) y la web (`actualizador-ui`).
- `Trabajador-GUI-Docker.ps1` ejecuta en Windows los trabajos que pide la GUI (cola en `gui-jobs/`).
- `Consola-Gestor-Docker.ps1` lo mismo por terminal (menu).
- `Copia-Externa.ps1` + `copias/` copia de UN proyecto a disco externo y verificacion.
- `Restaurar-Copia.ps1` restauracion desde ese disco (tambien viaja dentro de la copia).
- `proyectos-produccion.ejemplo.txt` modelo de configuracion. **El real (`proyectos-produccion.txt`)
  es local de cada equipo y no se versiona.**

Notas en `LEEME-*.txt` (la ultima: `LEEME-2.2-COPIA-EXTERNA-GUI.txt`).

## Primera vez en el servidor (carpeta que ya existe, con su estado local)

```powershell
cd C:\Users\ServerIT\Desktop
robocopy Docker-Autoarranque Docker-Autoarranque.antes-de-git /E /XD gui-jobs   # copia de seguridad
cd Docker-Autoarranque
git init -b main
git remote add origin https://github.com/Gestion2B/DockerGUI.git
git fetch origin
git reset --hard origin/main      # solo pisa ficheros versionados; proyectos-produccion.txt se queda
```

Luego, para actualizar: `git pull` y doble clic en `Abrir-GUI-Docker.cmd`.
