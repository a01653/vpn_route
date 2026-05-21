**Descripción**

VPN Route es una utilidad en PowerShell para Windows que corrige automáticamente la tabla de enrutamiento cuando una VPN cambia las rutas por defecto del sistema. Su objetivo es mantener el acceso a Internet por la red local, sin perder la conectividad hacia las redes internas que deben seguir pasando por la VPN.

**Requisito de instalación**

La aplicación debe estar ubicada en la ruta `C:\temp\vpn`. Los scripts están preparados para trabajar desde esa carpeta y usar ahí sus ficheros auxiliares y logs.

**Qué hace**

Aplica una configuración inicial de rutas para separar el tráfico: Internet sale por la red local y las subredes corporativas continúan por la VPN. Después deja un proceso en segundo plano que revisa periódicamente las rutas por defecto y las subredes internas definidas y, si la VPN las modifica o las pierde, restaura automáticamente la configuración prevista.

**Incluye**

* `INICIO.bat`: lanzador para ejecutar la aplicación con permisos elevados.
* `FINAL.ps1`: aplica la configuración inicial y arranca la supervisión.
* `reaplicar_loop.ps1`: vigila y reaplica las rutas automáticamente.
* `estado_vpn.ps1`: muestra el estado actual del bucle y un resumen de rutas.
* `parar_vpn.ps1`: detiene la supervisión.
* `detener_loop.ps1`: backend de parada usado por `parar_vpn.ps1`.
* `reaplicar_state.json`: fichero generado automáticamente con la LAN elegida y opciones de supervisión.
* `reaplicar_runtime.json`: fichero generado automáticamente con el PID y estado del bucle activo.
* `reaplicar_loop.stop`: fichero temporal de señal de parada cuando se solicita cerrar el bucle.

**Manual de uso**

1. Copiar todos los ficheros del proyecto en `C:\temp\vpn`.
2. Crear un acceso directo a `INICIO.bat` en el lugar que se desee.
3. Conectar la VPN.
4. Ejecutar `INICIO.bat` con permisos de administrador.
5. La aplicación detectará las conexiones de red locales válidas.
6. Si solo hay una red válida, la seleccionará automáticamente.
7. Si hay varias redes válidas, mostrará una lista para que el usuario elija cuál quiere usar como salida a Internet.
8. Después aplicará la configuración inicial de rutas y dejará activa la supervisión en segundo plano.
9. Para comprobar el estado, ejecutar `estado_vpn.ps1`.
10. Para detener la supervisión, ejecutar `parar_vpn.ps1`.

**Resultado esperado**

* Internet sigue funcionando por la red local seleccionada.
* Las redes internas definidas siguen saliendo por la VPN.
* Si la VPN modifica otra vez las rutas por defecto o pierde las subredes internas definidas, el sistema las corrige automáticamente.

**Importante**

* La aplicación debe mantenerse en `C:\temp\vpn`.
* La ejecución requiere permisos de administrador.
* La versión actual no fuerza DNS. Solo corrige rutas.
* Está pensada para Windows con PowerShell y debe ajustarse a las subredes internas reales de cada entorno.
