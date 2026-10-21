# AgentTray

Aplikacja w pasku menu macOS, która pokazuje, które sesje Claude Code czekają na Ciebie, a które pracują. Specyfikacja: [`docs/SPEC.md`](docs/SPEC.md), zasady pracy z kodem: [`docs/CLAUDE.md`](docs/CLAUDE.md).

## Build i uruchomienie

Wymaga macOS 15+ i Swift 6 (Xcode 16+ albo Command Line Tools).

```sh
./build.sh                 # buduje i podpisuje ad hoc build/AgentTray.app
open build/AgentTray.app
swift test                 # testy AgentTrayCore
```

`AgentTrayCore` to biblioteka wyłącznie na Foundation, więc `swift build` i `swift test` działają też na Linuksie. Target aplikacji jest wtedy pomijany.

## Struktura

- `Sources/AgentTrayCore`: parser JSONL (`TranscriptRecord`), model stanów (`reduce`, `classify`), przyrostowy czytnik transkryptów (`TranscriptReader`), rozwijanie wzorców (`PathPattern`), skaner katalogu `.claude` (`ClaudeDirectoryScanner`), sortowanie i grupowanie (`SessionListing`), teksty statusów (`StatusText`).
- `Sources/AgentTray`: `MenuBarExtra`, popover, ustawienia, FSEvents (`FileWatcher`), aktor `SessionMonitor` czytający pliki poza wątkiem głównym.
- `Tests/AgentTrayCoreTests`: testy na fixture'ach z `docs/fixtures` i na tymczasowych drzewach katalogów.

## Kontenery Speedwave

Ścieżka katalogów home kontenerów Speedwave na macOS nie jest jeszcze ustalona (patrz "Otwarte punkty" w specyfikacji). Po jej ustaleniu dopisz w ustawieniach wzorzec w rodzaju `~/<ścieżka>/*/home`; aplikacja sama zejdzie do podkatalogu `.claude`, a etykietą źródła będzie nazwa katalogu dopasowanego przez `*`.
