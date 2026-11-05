# iCamLink
Aplicacion para camaras DVR local

## macOS (Apple Silicon)

App nativa SwiftUI en `macos/`, con libvlc empaquetado (mismo motor que Android y Windows).

```bash
cd macos && ./build-app.sh   # genera dist/iCamLink.app y dist/iCamLink-<version>-macos-arm64.zip
```

Solo requiere las Command Line Tools. La primera vez descarga el VLC oficial arm64 a `macos/vendor/`.
La app queda firmada ad-hoc: si la copias a otro Mac, usa clic derecho → Abrir la primera vez.
