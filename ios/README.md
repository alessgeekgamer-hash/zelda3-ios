# Zelda 3 — Puerto iOS (IPA)

Puerto de *The Legend of Zelda: A Link to the Past* a iPhone/iPad usando el
motor [zelda3](https://github.com/snesrev/zelda3) (reimplementación en C con
licencia **MIT**) sobre SDL2, con launcher nativo, importación de ROM desde el
dispositivo y controles táctiles en pantalla. Sin Flutter: el juego es código
C/ObjC puro, porque Flutter no puede ejecutar el motor del juego.

Este repositorio **no contiene datos del juego**. Tú aportas tu propia ROM
(volcada de un cartucho que poseas), de la versión USA de 1 MiB
(CRC32 `777AAC2F`).

## 1. Obtener la IPA compilada en GitHub

La workflow `.github/workflows/ios.yml` compila la IPA en un runner macOS:

1. En este repositorio, entra en la pestaña **Actions** → **iOS**.
2. Si no hay ejecuciones, pulsa **Run workflow** (botón gris a la derecha).
3. Cuando termine (✅ verde), entra en la ejecución, baja hasta
   **Artifacts** y descarga **`zelda3-ipa`** (es un `.zip` con `zelda3.ipa`
   dentro).

> Los artifacts duran 90 días. Después, vuelve a pulsar *Run workflow*.

## 2. Instalar la IPA en el iPhone (Apple ID gratuito)

iOS solo ejecuta apps firmadas. Con tu Apple ID gratuito:

1. En PC (Windows/Mac), instala [Sideloadly](https://sideloadly.io/) o
   [AltStore](https://altstore.io/) con [AltServer](https://altstore.io/).
2. Conecta el iPhone por USB (o en red, según la herramienta).
3. Arrastra `zelda3.ipa` y firma con tu Apple ID (nunca la contraseña real:
   la App Store Specific Password si te lo pide).
4. En el iPhone: *Ajustes → General → VPN y administración de dispositivo* →
   confiar en tu ID de desarrollador.
5. Abre **Zelda 3**.

⚠️ La firma gratuita caduca a los **7 días**: renueva repitiendo el paso 3
(AltStore con suscripción de pago renueva sola por Wi-Fi). ParaIPA estable de
1 año hace falta cuenta de desarrollador Apple de pago ($99/año).

## 3. Importar la ROM

Dentro de la app: **Seleccionar ROM…** y elige tu `zelda3.sfc` (o `.smc`,
también acepta archivo con cabecera de 512 bytes; la app la quita sola).

Alternativa: la app comparte su carpeta en el navegador de archivos — abre
**Archivos → En este iPhone → Zelda 3** y copia `zelda3.sfc` ahí.

En el primer arranque la app genera `zelda3_assets.dat` a partir de tu ROM
(parche `zelda3_assets.bps` incluido) y a partir de ahí la ROM ya no hace
falta para jugar (pero no la borres si quieres poder reinstalar).

## Controles

| En pantalla | Función |
|---|---|
| Cruceta | Movimiento (con diagonales) |
| A / B / X / Y | Como en el SNES (colocación original) |
| L / R | Hombros |
| START / SELECT | Menú / selección |

Mandos Bluetooth (Xbox, PlayStation, Switch Pro…) se detectan solos y los
controles táctiles se ocultan mientras se usan.

Atajos del motor (teclado, si conectas uno): `Enter`=Start, `Shift der.`=Select.

## Guardados

- Partida: `saves/` de la app (se guarda automáticamente al pasar a segundo
  plano y al salir).
- Visible en **Archivos → Zelda 3** junto a `zelda3.ini` (configuración).

## Compilar localmente (macOS)

```sh
git clone --recursive https://github.com/alessgeekgamer-hash/zelda3-ios
cd zelda3-ios
cmake -S ios -B build-ios -G Xcode -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
cmake --build build-ios --config Release
# El .app queda en build-ios/Release-iphoneos/zelda3.app
```

Xcode + línea de comandos de Apple son imprescindibles; en Windows solo se
puede compilar la IPA desde GitHub Actions (lo de arriba).

## Aviso legal

El código del puerto y de zelda3 es MIT; SDL2, zlib. Los gráficos y sonidos
del juego son propiedad de Nintendo: no redistribuyas la ROM ni
`zelda3_assets.dat`. Proyecto de fan, sin relación con Nintendo.
