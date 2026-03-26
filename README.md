**Descripción**
VPN Route es una utilidad en PowerShell para Windows que corrige automáticamente la tabla de enrutamiento cuando una VPN cambia las rutas por defecto del sistema. Su objetivo es mantener el acceso a Internet por la conexión local, sin perder la conectividad hacia las redes internas que deben seguir pasando por la VPN.

**Qué hace**
La herramienta aplica una configuración inicial de rutas para separar el tráfico: Internet sale por la red local y las subredes corporativas continúan por la VPN. Después deja un proceso de supervisión en segundo plano que revisa periódicamente la tabla de rutas y, si la VPN la modifica, restaura automáticamente la configuración prevista.

**Incluye**

* Script de inicio de configuración.
* Script de supervisión y reaplicación automática.
* Script de consulta de estado.
* Script para detener el proceso de supervisión.

**Manual de uso**

1. Conecta primero la VPN.
2. Ejecuta `FINAL.ps1` con PowerShell.
3. El script detectará la interfaz local válida y aplicará las rutas necesarias.
4. A partir de ese momento, quedará activo un proceso en segundo plano que vigila cambios en la tabla de enrutamiento.
5. Para comprobar el estado, ejecuta `estado_vpn.ps1`.
6. Para detener la supervisión, ejecuta `detener_loop.ps1`.

**Resultado esperado**

* Internet sigue funcionando por la red local.
* Las redes internas definidas siguen saliendo por la VPN.
* Si la VPN modifica de nuevo las rutas, el sistema las corrige automáticamente.

**Importante**
Está pensado para entornos Windows con PowerShell y debe ajustarse a las subredes internas reales de cada organización.
