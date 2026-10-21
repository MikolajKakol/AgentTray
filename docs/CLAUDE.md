# AgentTray

Aplikacja macOS w pasku menu, która pokazuje stan sesji Claude Code. Pełna specyfikacja: `SPEC.md`. Przed zmianą reguł stanu przeczytaj sekcję "Model stanów".

## Build

- Swift Package (`Package.swift`), bez projektu Xcode. Targety: `AgentTrayCore` (biblioteka, tylko Foundation), `AgentTray` (executable, SwiftUI), `AgentTrayCoreTests`.
- Minimum: macOS 15, Swift 6, tryb ścisłej współbieżności.
- `./build.sh` robi `swift build -c release`, składa `build/AgentTray.app` (`Contents/MacOS/AgentTray`, `Contents/Info.plist` z `LSUIElement = true`, `CFBundleIdentifier = local.agenttray`) i podpisuje ad hoc: `codesign --force --sign - build/AgentTray.app`.
- Testy: `swift test`.
- Bez zewnętrznych zależności SwiftPM.

## Zasady

- Aplikacja tylko czyta pliki w śledzonych katalogach `.claude`. Żaden kod nie może w nich tworzyć, zmieniać ani usuwać plików, także tymczasowych.
- Cała logika formatu JSONL i stanu żyje w `AgentTrayCore` jako czyste funkcje z jawnym `now: Date`. UI nie parsuje JSON.
- Parser ignoruje nieznane typy rekordów i nieznane pola. Format transkryptu Claude Code zmienia się między wersjami.
- Każda zmiana reguły stanu wymaga fixture'a w `fixtures/` i testu. Fixture'y z prawdziwych sesji anonimizuj: treść promptów, wiadomości, bloków `thinking` i wyników narzędzi zastąp neutralnym tekstem, usuń `signature`, `requestId` i ścieżki prywatne.
- Teksty w UI po polsku.
