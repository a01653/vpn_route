**Descripción**

VPN Route es una utilidad en PowerShell para Windows que corrige automáticamente la tabla de enrutamiento cuando una VPN cambia las rutas por defecto del sistema. Su objetivo es mantener el acceso a Internet por la conexión local, sin perder la conectividad hacia las redes internas que deben seguir pasando por la VPN.

**Requisito de instalación**

La aplicación debe estar ubicada en la ruta:

`C:\temp\vpn`

Los scripts están preparados para trabajar desde esa carpeta y usar ahí sus ficheros auxiliares y logs.

**Qué hace**

Aplica una configuración inicial de rutas para separar el tráfico: Internet sale por la red local y las subredes corporativas continúan por la VPN. Después deja un proceso en segundo plano que revisa periódicamente la tabla de rutas y, si la VPN la modifica, restaura automáticamente la configuración prevista.

**Incluye**

* `INICIO.bat`: lanzador para crear un acceso directo y ejecutar la aplicación con permisos elevados.
* `FINAL.ps1`: aplica la configuración inicial y arranca la supervisión.
* `reaplicar_loop.ps1`: vigila y reaplica las rutas automáticamente.
* `estado_vpn.ps1`: muestra el estado actual.
* `detener_loop.ps1`: detiene la supervisión.

**Manual de uso**

1. Copiar todos los ficheros del proyecto en `C:\temp\vpn`.
2. Crear un acceso directo a `INICIO.bat` en el lugar que se desee.
3. Usar ese acceso directo para iniciar la aplicación con permisos elevados.
4. Conectar la VPN.
5. Ejecutar `INICIO.bat`, que lanzará el proceso necesario con privilegios de administrador.
6. El script aplicará la configuración inicial de rutas y dejará activa la supervisión en segundo plano.
7. Para comprobar el estado, ejecutar `estado_vpn.ps1`.
8. Para detener la supervisión, ejecutar `detener_loop.ps1`.

**Resultado esperado**

* Internet sigue funcionando por la red local.
* Las redes internas definidas siguen saliendo por la VPN.
* Si la VPN modifica otra vez las rutas, el sistema las corrige automáticamente.

**Importante**

* La aplicación debe mantenerse en `C:\temp\vpn`.
* La ejecución requiere permisos de administrador.
* Está pensada para Windows con PowerShell y debe ajustarse a las subredes internas reales de cada entorno.
