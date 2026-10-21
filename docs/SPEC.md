# AgentTray: specyfikacja

AgentTray to aplikacja w pasku menu macOS. Pokazuje, które sesje Claude Code (lokalne i uruchomione w kontenerach Speedwave) czekają na wkład użytkownika, a które pracują: myślą, wykonują narzędzie, monitorują coś w tle albo czekają na subagentów. Dla każdej sesji wyświetla ostatni prompt i ostatnią wiadomość agenta.

Aplikacja jest prywatnym narzędziem jednej osoby. Nie jest dystrybuowana ani notaryzowana.

## Zakres

W zakresie:

- odczyt plików stanu Claude Code z dowolnej liczby katalogów `.claude` podanych jako wzorce z wildcardami;
- wyznaczanie stanu każdej sesji wyłącznie z plików (transkrypty JSONL i `sessions/*.json`);
- ikona w pasku menu z licznikiem sesji czekających na użytkownika i popover z listą sesji;
- oznaczanie sesji jako przejrzanych (stan trzymany w `UserDefaults` aplikacji, nie w `.claude`);
- okno ustawień.

Poza zakresem (decyzje, nie przeoczenia):

- żadnych zapisów do katalogów `.claude`, żadnych hooków, żadnej modyfikacji `settings.json`; aplikacja tylko czyta;
- brak odpowiadania agentowi z aplikacji (zatwierdzanie zgód, wysyłanie promptów);
- brak przechodzenia do terminala lub okna Speedwave po kliknięciu;
- brak powiadomień systemowych; jedynym sygnałem jest ikona w pasku menu;
- brak listy subagentów; wystarczy stan "czeka na subagentów (N)";
- brak App Sandbox, brak notaryzacji, brak instalatora.

## Platforma

- macOS 15 jako minimum (użytkownik ma macOS 27).
- Swift 6, SwiftUI, `MenuBarExtra` w stylu `.window`, `@Observable`.
- Swift Package bez projektu Xcode. Szczegóły builda w `CLAUDE.md`.
- `LSUIElement = true` (brak ikony w Docku).
- Jedna instancja: przy starcie aplikacja kończy działanie, jeśli działa już inny proces z tym samym bundle id (np. jeden uruchomiony przy logowaniu, drugi ręcznie).
- Uruchamianie przy logowaniu przez `SMAppService.mainApp`, przełączane w ustawieniach.

## Źródła danych

### Katalogi

Ustawienia zawierają listę wzorców ścieżek. Każdy wzorzec po rozwinięciu wskazuje katalog `.claude`. Jeśli dopasowany katalog nie zawiera ani `sessions/`, ani `projects/`, a zawiera podkatalog `.claude`, aplikacja używa tego podkatalogu (wzorzec wskazał katalog home).

Składnia wzorców:

- `~` na początku rozwija się do katalogu domowego użytkownika;
- `*` dopasowuje dokładnie jeden segment ścieżki (bez `/`);
- `**` dopasowuje zero lub więcej segmentów, z limitem głębokości 6;
- pozostałe znaki dopasowują się dosłownie.

Przykłady: `~/.claude`, `~/Speedwave/*/home/.claude`, `/Volumes/dev/**/.claude`.

Wzorce są rozwijane ponownie co 30 s oraz po każdym zdarzeniu FSEvents na najgłębszym katalogu wzorca bez wildcardów, więc nowy projekt Speedwave pojawia się bez restartu. Ten sam katalog dopasowany przez kilka wzorców jest śledzony raz (porównanie po ścieżce kanonicznej, `resolvingSymlinksInPath`).

Domyślna lista wzorców: `["~/.claude"]`. [Niezweryfikowane] Nie wiadomo, pod jaką ścieżką Speedwave Desktop trzyma katalogi home kontenerów na macOS. W kontenerze `/home/speedwave` (razem z `.claude`) jest zamontowany z dysku hosta. Ścieżkę trzeba ustalić na Macu i dopisać ręcznie w ustawieniach.

### Struktura katalogu `.claude`

Zweryfikowane na Claude Code 2.1.295:

```
.claude/
  sessions/<pid>.json                          # rejestr żywych i martwych procesów
  projects/<zakodowany-cwd>/<sessionId>.jsonl  # transkrypt sesji
  projects/<zakodowany-cwd>/<sessionId>/subagents/agent-<id>.jsonl
  projects/<zakodowany-cwd>/<sessionId>/subagents/agent-<id>.meta.json
```

`<zakodowany-cwd>` to ścieżka robocza z `/` zamienionym na `-`, np. `-workspace`. Aplikacja nie dekoduje tej nazwy; katalog roboczy bierze z pola `cwd` rekordów.

Transkrypty subagentów (`subagents/`) nie są potrzebne do wyznaczania stanu. Aplikacja ich nie czyta.

### `sessions/<pid>.json`

Przykład: `fixtures/sessions-3398.json`. Pola używane przez aplikację:

- `sessionId`: klucz łączący z transkryptem;
- `name`: nazwa sesji (np. `workspace-56`);
- `status`: `idle` albo `busy`;
- `updatedAt`, `statusUpdatedAt`: milisekundy od epoki.

Ograniczenia:

- pliki po zamkniętych sesjach zostają na dysku, a `pid` i `pidDomain` pochodzą z przestrzeni nazw kontenera, więc z hosta nie da się sprawdzić, czy proces żyje;
- `sessionId` może wskazywać sesję bez transkryptu (sesja bez żadnej wiadomości); taką sesję aplikacja pomija;
- `status` jest sygnałem pomocniczym, nie źródłem stanu (patrz "Model stanów").

Obok plików `.json` leżą pliki `<pid>.<hash>.key`. Aplikacja je ignoruje i nie otwiera.

### Transkrypt JSONL

Jedna linia to jeden obiekt JSON z polem `type`. Aplikacja musi ignorować nieznane typy i nieznane pola. Rekordy z `isSidechain: true` są pomijane.

Typy używane przez aplikację:

| `type` | Pola | Znaczenie |
|---|---|---|
| `user` | `message.content` (string lub tablica bloków), `origin.kind`, `isMeta`, `timestamp`, `toolUseResult`, `permissionDecision` | prompt użytkownika, wynik narzędzia albo powiadomienie o zadaniu w tle |
| `assistant` | `message.content` (tablica z jednym blokiem), `message.stop_reason`, `timestamp` | jeden blok odpowiedzi: `thinking`, `text` albo `tool_use` |
| `system` z `subtype: "turn_duration"` | `durationMs`, `pendingBackgroundAgentCount` (opcjonalne), `timestamp` | koniec tury agenta |
| `queue-operation` | `operation` (`enqueue`, `dequeue`, `remove`), `content`, `timestamp` | kolejka wiadomości do sesji, w tym `<task-notification>` |
| `last-prompt` | `lastPrompt` | ostatni prompt użytkownika, zapisany wprost |
| `custom-title` | `customTitle` | nazwa nadana przez użytkownika |
| `ai-title` | `aiTitle` | nazwa wygenerowana przez model |
| `permission-mode` | `permissionMode` (np. `default`, `bypassPermissions`) | aktualny tryb zgód |

Fakty o formacie, zweryfikowane na prawdziwych transkryptach:

- Każdy rekord `assistant` zawiera dokładnie jeden blok w `message.content`. Odpowiedź z myśleniem, tekstem i wywołaniem narzędzia to trzy kolejne rekordy.
- `stop_reason` przyjmuje wartości `tool_use`, `end_turn`, `stop_sequence`; ten sam `stop_reason` jest powielany na wszystkich rekordach jednej odpowiedzi.
- Wynik narzędzia to rekord `user` z blokiem `{"type":"tool_result","tool_use_id":...}` i polem `toolUseResult`.
- Prompt użytkownika to rekord `user` z `origin.kind == "human"` i `message.content` jako string.
- Uruchomienie zadania Bash w tle: `toolUseResult.backgroundTaskId` (np. `"brdtffwa0"`).
- Uruchomienie subagenta w tle: `toolUseResult` z `isAsync: true`, `status: "async_launched"`, `agentId`.
- Subagent na pierwszym planie: `tool_use` o nazwie `Agent` bez wyniku do czasu zakończenia; wynik ma `toolUseResult.status: "completed"`.
- Zakończenie zadania w tle: rekord `queue-operation` z `operation: "enqueue"` i `content` zawierającym `<task-notification>` z `<task-id>`, `<tool-use-id>` i `<status>completed</status>`. Następnie, gdy sesja go przetworzy, rekord `user` z `origin.kind == "task-notification"` i tą samą treścią.
- `system/turn_duration` ma opcjonalne pole `pendingBackgroundAgentCount`, gdy w momencie końca tury działają subagenci w tle.
- `permissionDecision` na wynikach narzędzi ma kształt `{"decision":"accept","source":"config","reasonType":"mode"}` (zgoda z konfiguracji) albo `{"decision":"accept","source":"user_temporary"}` (zgoda kliknięta przez użytkownika). Pole pojawia się dopiero razem z wynikiem, więc nie pozwala wykryć oczekiwania na zgodę.

Niezweryfikowane (brak przykładów w dostępnych transkryptach; potwierdzić na prawdziwej sesji i dopisać fixture):

- format wyniku narzędzia `Monitor` i rekordu jego zakończenia lub wygaśnięcia;
- format `ScheduleWakeup` i rekordu wybudzenia;
- wartości `<status>` w `<task-notification>` inne niż `completed` (zakładamy `failed`, `killed`, `timeout`);
- rekord przerwania tury przez użytkownika (Esc/Ctrl+C); zakładamy rekord `user` z treścią zaczynającą się od `[Request interrupted by user`;
- jakikolwiek ślad prośby o zgodę na narzędzie w transkrypcie (w zbadanych plikach nie ma żadnego).

## Model stanów

### Fakty pośrednie

Dla każdej sesji parser utrzymuje, przetwarzając rekordy po kolei:

- `openToolUses`: mapa `tool_use.id` na `(name, input, timestamp)` dla wywołań bez wyniku;
- `backgroundTasks`: zbiór identyfikatorów zadań w tle uruchomionych i jeszcze niezakończonych. Dodanie: `toolUseResult.backgroundTaskId` albo `toolUseResult.agentId` przy `status == "async_launched"`. Usunięcie: `<task-id>` z dowolnego `<task-notification>` (w `queue-operation` albo w rekordzie `user`). Rodzaj zadania (`agent` albo `task`) wynika ze sposobu uruchomienia;
- `pendingBackgroundAgents`: `pendingBackgroundAgentCount` z ostatniego `turn_duration`, pomniejszone o powiadomienia o subagentach, które przyszły po nim; brak pola oznacza 0;
- `turnEnded`: `true` po rekordzie `turn_duration` albo po rekordzie przerwania; `false` po promptcie użytkownika, po rekordzie `user` z `origin.kind == "task-notification"` i po każdym rekordzie `assistant`;
- `permissionMode`: wartość z ostatniego `permission-mode`;
- `lastActivity`: maksimum z `timestamp` ostatniego rekordu, mtime pliku JSONL i `updatedAt` z `sessions/*.json`;
- `lastPrompt`: `lastPrompt` z ostatniego `last-prompt`; jeśli brak, treść ostatniego rekordu `user` z `origin.kind == "human"`;
- `lastMessage`: tekst ostatniego bloku `text` z rekordu `assistant`;
- `title`: `customTitle` > `aiTitle` > `name` z `sessions/*.json` > pierwsze 8 znaków `sessionId`.

Rekordy `user` z `isMeta: true` nie zmieniają `turnEnded` ani `lastPrompt`.

### Stany

Stan wyznacza się regułami w tej kolejności; wygrywa pierwsza pasująca.

| Stan | Reguła | Grupa |
|---|---|---|
| `askingQuestion` | w `openToolUses` jest `AskUserQuestion` albo `ExitPlanMode` | czeka na Ciebie |
| `waitingForSubagents(n)` | w `openToolUses` jest `Agent` lub `Task` (n = ich liczba), albo `turnEnded` i `pendingBackgroundAgents > 0` (n = ta liczba) | pracuje |
| `runningTool(name, summary)` | w `openToolUses` jest inne narzędzie i (`permissionMode == "bypassPermissions"` albo wywołanie trwa krócej niż próg niepewności) | pracuje |
| `maybeAwaitingPermission(name, summary)` | w `openToolUses` jest inne narzędzie, tryb inny niż `bypassPermissions` i wywołanie trwa co najmniej próg niepewności (domyślnie 10 s) | niepewny |
| `monitoring(n)` | `turnEnded` i w `backgroundTasks` jest n > 0 zadań rodzaju `task` | pracuje |
| `yourTurn` | `turnEnded` | czeka na Ciebie |
| `thinking` | pozostałe przypadki (tura trwa, brak otwartych narzędzi) | pracuje |

Uwagi:

- Kilka otwartych narzędzi naraz (wywołania równoległe): `askingQuestion` ma pierwszeństwo, potem subagenci, potem pozostałe; `summary` dotyczy najstarszego otwartego wywołania.
- `summary` narzędzia: dla `Bash` pole `description`, a gdy brak, pierwsze 60 znaków `command`; dla `Read`, `Edit`, `Write` nazwa pliku z `file_path`; dla innych sama nazwa narzędzia.
- `status: "busy"` z `sessions/*.json` przy stanie `yourTurn` nie zmienia stanu, bo plik może być nieaktualny po zabitym procesie.
- Stan `thinking` przy bardzo starej aktywności (np. proces zabity w trakcie tury) obsługuje przyciemnianie i ukrywanie, a nie osobny stan.

### Wiek sesji

Niezależnie od stanu:

- `lastActivity` starsze niż 10 h: wiersz przyciemniony, sesja nie liczy się do licznika w ikonie;
- `lastActivity` starsze niż 40 h: sesja ukryta;
- oba progi są w ustawieniach.

## Odczyt plików

- Obserwacja: FSEvents na każdym śledzonym katalogu `.claude` (rekursywnie dla `sessions/` i `projects/`), z debounce 300 ms. Zdarzenia wyzwalają odczyt tylko zmienionych plików.
- Pierwszy odczyt transkryptu: ostatnie 256 KB. Pierwsza (prawdopodobnie ucięta) linia okna jest odrzucana. Jeśli w oknie nie ma `last-prompt` ani tytułu, parser cofa się o kolejne 256 KB, aż je znajdzie albo dojdzie do początku pliku. `openToolUses` i `backgroundTasks` z uciętego okna mogą być niepełne; to akceptowalne, bo zadania starsze niż okno i tak zwykle się zakończyły.
- Kolejne odczyty: od zapamiętanego offsetu, tylko nowe bajty. Niepełna ostatnia linia (bez `\n`) czeka w buforze na kolejny odczyt.
- Plik krótszy niż zapamiętany offset albo z innym inode: pełny ponowny odczyt od okna 256 KB.
- Linia, której nie da się sparsować jako JSON: pomijana i logowana (`os.Logger`, kategoria `parser`), bez przerywania odczytu.
- Sesja znika z listy, gdy jej plik JSONL zniknie.
- Odczyt i parsowanie poza wątkiem głównym; UI dostaje gotowe migawki stanu.
- Zegar 1 s odświeża czasy względne i przejście w `maybeAwaitingPermission` po upływie progu.

## Interfejs

### Ikona w pasku menu

- Brak sesji w grupie "czeka na Ciebie": sama ikona (SF Symbol, np. `circle.grid.2x2`).
- Są takie sesje: ikona z liczbą (np. `2`), wypełniona.
- Jest co najmniej jedna sesja w stanie `maybeAwaitingPermission`: ikona w wersji z obrysem, niezależnie od licznika. Sesje niepewne nie wliczają się do licznika.
- Do licznika nie wliczają się sesje przyciemnione ani przejrzane.

### Przejrzane sesje

Sesja z grupy "czeka na Ciebie" albo "niepewny" może zostać oznaczona jako przejrzana (przycisk w wierszu albo "Przejrzyj wszystkie" w stopce). Aplikacja zapamiętuje wtedy znacznik sesji: `timestamp` ostatniego rekordu, który posuwa rozmowę naprzód (gdy brak, `timestamp` ostatniego rekordu, a gdy i tego brak, `lastActivity`). Rozmowę posuwają: rekord `user` bez `isMeta` (prompt, wynik narzędzia, powiadomienie o zadaniu), rekord `assistant`, `system/turn_duration` i `queue-operation` z `<task-notification>`. Sesja pozostaje przejrzana, dopóki znacznik się nie zmieni. Nie cofają oznaczenia rekordy dopisywane po końcu tury: `ai-title`, `last-prompt`, podsumowanie po powrocie do terminala ("※ recap"), `system` o innych podtypach (np. `stop_hook_summary`), `attachment`, rekordy `user` z `isMeta: true` i nieznane typy. [Niezweryfikowane] Dokładny format rekordu "recap" nie jest znany; reguła nie zależy od niego, o ile nie jest to rekord `assistant` ani `user` bez `isMeta`. Przejrzana sesja:

- nie wlicza się do licznika i nie włącza ikony z obrysem;
- trafia do osobnej grupy "Przejrzane", wyświetlanej przyciemniona;
- ma przycisk "Przywróć do licznika".

Sesje pracujące nie są oznaczane. Oznaczenia sesji, które zniknęły z listy, są usuwane.

### Popover

Lista sesji posortowana grupami:

1. `askingQuestion`, potem `yourTurn`;
2. `maybeAwaitingPermission`;
3. pracujące (`thinking`, `runningTool`, `waitingForSubagents`, `monitoring`);
4. przejrzane;
5. przyciemnione (starsze niż 10 h), w dowolnym stanie.

W obrębie grupy: od najdłużej trwającego stanu (najstarsze `lastActivity` pierwsze).

Wiersz sesji:

- pierwsza linia: `title`, a obok etykieta źródła i nazwa katalogu roboczego (ostatni segment `cwd`);
- druga linia: stan po polsku i czas od `lastActivity` ("czeka na Ciebie · 4 min", "wykonuje: Run tests · 12 s", "czeka na subagentów (2)", "monitoruje (1)", "może czekać na zgodę: Bash · 25 s");
- ostatni prompt, przycięty do 2 linii;
- ostatnia wiadomość, przycięta do 2 linii; gdy stan to `runningTool` lub `maybeAwaitingPermission`, w tym miejscu "Nazwa: summary" zamiast tekstu.

Kliknięcie wiersza rozwija pełny prompt i pełną wiadomość (przewijane, z możliwością zaznaczenia i skopiowania tekstu). Kolejne kliknięcie zwija.

Etykieta źródła: dla katalogu `~/.claude` tekst "lokalny"; dla pozostałych segment ścieżki dopasowany przez pierwszy `*` we wzorcu, a gdy wzorzec nie ma wildcardów, nazwa katalogu nadrzędnego dla `.claude` (lub dla katalogu home).

Stopka popovera: "Ustawienia…", "Przejrzyj wszystkie" (gdy jest co oznaczyć) i "Zakończ".

Lista i rozwinięty tekst wiersza mają wysokość dopasowaną do zawartości (lista do 560 pt, tekst do 240 pt), dalej przewijają się.

Pusta lista: tekst "Brak aktywnych sesji" i liczba śledzonych katalogów.

### Ustawienia

Okno `Settings` z polami:

- lista wzorców ścieżek: dodawanie, edycja, usuwanie; przy każdym wzorcu liczba dopasowanych katalogów `.claude` (aktualizowana na żywo) albo komunikat "brak dopasowań";
- przyciemniaj po (h), domyślnie 10;
- ukrywaj po (h), domyślnie 40; walidacja: większe niż próg przyciemniania;
- próg niepewnego stanu (s), domyślnie 10;
- przełącznik "Uruchamiaj przy logowaniu" (`SMAppService.mainApp`).

Ustawienia w `UserDefaults`.

## Architektura

Dwa moduły:

- `AgentTrayCore` (biblioteka, tylko Foundation): rozwijanie wzorców, parser JSONL, reduktor stanu sesji, czytnik plików z offsetami, sortowanie i grupowanie. Wszystkie funkcje zależne od czasu przyjmują `now: Date` jako parametr.
- `AgentTray` (aplikacja, SwiftUI + AppKit): FSEvents, timery, `MenuBarExtra`, ustawienia, `SMAppService`.

Rdzeń modelu stanów to czysta funkcja: `reduce(state: SessionFacts, record: TranscriptRecord) -> SessionFacts` oraz `classify(facts: SessionFacts, settings: Thresholds, now: Date) -> SessionStatus`. Interfejs UI nie zna formatu JSONL.

## Testy

Testy jednostkowe `AgentTrayCore` (XCTest lub Swift Testing) na fixture'ach z `fixtures/`. Fixture'y to zanonimizowane i skrócone transkrypty w formacie z Claude Code 2.1.295. Oczekiwane wyniki:

| Fixture | Oczekiwany stan | Dodatkowo |
|---|---|---|
| `01-turn-ended.jsonl` | `yourTurn` | `lastPrompt` = "Dodaj walidację formularza logowania", `lastMessage` = "Walidacja dodana, 12 testów przechodzi.", `title` = "Walidacja formularza logowania" |
| `02-thinking.jsonl` | `thinking` | |
| `03-tool-running.jsonl` | `runningTool("Bash", "Run tests")` przy `now` < 10 s od wywołania; `maybeAwaitingPermission` przy `now` ≥ 10 s | tryb `default` |
| `04-tool-running-bypass.jsonl` | `runningTool` niezależnie od czasu | tryb `bypassPermissions` |
| `05-ask-user-question.jsonl` | `askingQuestion` | |
| `06-subagent-foreground.jsonl` | `waitingForSubagents(1)` | |
| `07-subagents-background.jsonl` | `waitingForSubagents(2)` | `lastMessage` = "Uruchomiłem dwóch agentów w tle, czekam na wyniki." |
| `08-subagent-notified.jsonl` | `waitingForSubagents(1)` | |
| `09-background-bash.jsonl` | `monitoring(1)` | |

`sessions-3398.json` testuje dekodowanie rejestru sesji, a `subagent.meta.json` jest próbką formatu metadanych subagenta (nieużywaną przez aplikację).

Dodatkowe testy:

- rozwijanie wzorców na tymczasowym drzewie katalogów: `*`, `**` z limitem głębokości, `~`, fallback z katalogu home na `.claude`, deduplikacja;
- odczyt przyrostowy: dopisanie linii, niepełna ostatnia linia, obcięcie pliku, linia z niepoprawnym JSON;
- pierwsze okno 256 KB z cofaniem po `last-prompt`;
- sortowanie i progi wieku (10 h, 40 h) przy sztucznym `now`;
- nieznany `type` rekordu i nieznane pola nie powodują błędu.

UI bez testów automatycznych.

## Kryteria akceptacji

1. `./build.sh` na macOS 15+ buduje `AgentTray.app`, który uruchamia się bez ikony w Docku i pokazuje ikonę w pasku menu.
2. Z domyślnym wzorcem `~/.claude` aplikacja pokazuje lokalne sesje Claude Code. Sesja, której tura się skończyła, pojawia się w grupie "czeka na Ciebie" w ciągu 1 s od zapisu `turn_duration`.
3. Po dopisaniu w ustawieniach wzorca z `*` wskazującego katalogi kontenerów Speedwave sesje z kontenerów pojawiają się bez restartu, z etykietą źródła równą nazwie dopasowanego katalogu.
4. Sesja z otwartym `AskUserQuestion` jest na górze listy i wliczona do licznika w ikonie.
5. Sesja z subagentami w tle pokazuje "czeka na subagentów (N)" także po zakończeniu tury i nie jest liczona jako czekająca na użytkownika.
6. Aplikacja nie tworzy, nie modyfikuje i nie usuwa żadnego pliku w śledzonych katalogach (sprawdzalne przez `fs_usage -w -f filesys AgentTray`).
7. Transkrypt 10 MB nie powoduje zauważalnego przycięcia UI przy pierwszym odczycie, a zużycie pamięci przy 20 śledzonych sesjach nie przekracza 100 MB.
8. Wszystkie testy z sekcji "Testy" przechodzą (`swift test`).

## Otwarte punkty do weryfikacji podczas implementacji

Każdy z nich wymaga uruchomienia prawdziwej sesji Claude Code, zapisania fragmentu transkryptu jako nowego fixture'a i ewentualnej korekty reguł:

- ścieżka katalogów home kontenerów Speedwave na macOS (do wpisania w ustawieniach i w README);
- format zakończenia i wygaśnięcia `Monitor` oraz to, czy jego uruchomienie zwraca `backgroundTaskId`;
- `ScheduleWakeup` (`/loop`): czy zaplanowane wybudzenie powinno dawać stan `monitoring`; jeśli tak, reguła na podstawie `input.delaySeconds` i `timestamp` wywołania;
- rekord przerwania tury;
- statusy `<task-notification>` inne niż `completed`.
