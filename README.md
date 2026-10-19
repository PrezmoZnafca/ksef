# Automat do pobierania i drukowania faktur z KSeF

Dwa niezależne komponenty + folder roboczy na Pulpicie:

1. **Skrypt przeglądarkowy** — zakładka (bookmarklet) w przeglądarce, klikana ręcznie, bez
   instalowania żadnego rozszerzenia:
   - `bookmarklet/ksef-auto-pobieranie-bookmarklet.js` (czytelne źródło) +
     `ksef-bookmarklet-url.txt` (wygenerowany URL do wklejenia jako zakładka)

   Po Twoim ręcznym zalogowaniu do KSeF i kliknięciu zakładki pokazuje panel z wyborem zakresu dat (ten / poprzedni /
   następny miesiąc albo własny zakres). Po kliknięciu Start: przełącza na zakładkę "Faktury
   zakupowe", ustawia filtr "Rodzaj daty" = "Data wystawienia" i wpisuje wybrany zakres, ustawia
   50 wierszy na stronę, po czym zaznacza checkboxy i pobiera faktury w paczkach po 10 (limit
   KSeF) jako PDF, pomijając te już pobrane wcześniej (pamięta po numerze KSeF). Paczki .zip
   lądują w normalnym folderze **Downloads** (Chrome).
2. **`powershell/Drukuj-Faktury.ps1`** — aplikacja (okno) uruchamiana ręcznie po zakończeniu
   pobierania. Przy starcie sama synchronizuje nowe paczki .zip z Downloads do
   `Pulpit\KSEF\do druku` i pokazuje listę oczekujących faktur. Wybierz zakres dat (bieżący /
   poprzedni / następny miesiąc albo własny zakres) i kliknij "Drukuj" — skrypt scala pasujące
   faktury (w kolejności dat wystawienia) w **jeden plik PDF** i drukuje go jako **pojedyncze
   zadanie druku**, cicho, dwustronnie i czarno-biało, na domyślnej drukarce. Jedno zadanie
   zamiast osobnego na każdą fakturę — przy 100 fakturach osobne zadania potrafiły zapychać
   kolejkę wydruku.

## Foldery robocze (Pulpit\KSEF)

- `do druku` — PDF-y oczekujące na wydruk (jeszcze niewydrukowane).
- `wydrukowane` — PDF-y już wydrukowane (trafiają tu automatycznie po druku).
- `zip archiwum` — oryginalne paczki .zip pobrane z KSeF, zachowane jako kopia zapasowa.

Po wydruku w `wydrukowane` ląduje też plik `scalone_<data>_<zakres>.pdf` — dokładna kopia tego,
co poszło do drukarki jako jedno zadanie (przydatne jako archiwum/dowód na wszelki wypadek).
Plik `log.txt` w `KSEF\` zawiera historię wszystkich uruchomień (przydatne do debugowania,
gdyby okno się zamknęło po błędzie).

Ten sam folder co repo skryptów (`c:\Users\48665\Desktop\ksef` = `Pulpit\KSEF`, Windows nie
rozróżnia wielkości liter w nazwach folderów).

## Instalacja (jednorazowo)

### Bookmarklet (bez rozszerzenia)

1. Otwórz plik [`bookmarklet/ksef-bookmarklet-url.txt`](bookmarklet/ksef-bookmarklet-url.txt)
   w edytorze tekstu, zaznacz całą zawartość (jedna długa linia zaczynająca się od
   `javascript:`) i skopiuj.
2. W Chrome: prawy klik na pasku zakładek → **Dodaj stronę** (Add page). Jako **Nazwa** wpisz
   np. "KSeF - pobieranie faktur", jako **URL** wklej skopiowaną zawartość → Zapisz.
   (Jeśli pasek zakładek jest ukryty: `Ctrl+Shift+B` żeby go pokazać.)
3. Będąc na liście faktur w KSeF, kliknij tę zakładkę - pojawi się panel automatu.
4. Jeśli kiedyś zmieni się kod źródłowy (`ksef-auto-pobieranie-bookmarklet.js`), trzeba
   wygenerować nowy `ksef-bookmarklet-url.txt` (wymaga zainstalowanego Node.js):
   ```
   node bookmarklet/generate-bookmarklet.js
   ```
   i zaktualizować URL zakładki w przeglądarce (edytuj zakładkę → wklej nową zawartość pliku).

### Wspólne dla obu wariantów

1. W Chrome wejdź na `chrome://settings/downloads` i **wyłącz** opcję "Pytaj gdzie zapisać każdy
   plik przed pobraniem" — inaczej każde pobranie paczki .zip zatrzyma się na oknie systemowym,
   którego skrypt nie potrafi obsłużyć.
0. Na nowym komputerze uruchom dwuklikiem `Zainstaluj wymagane programy.bat` — zainstaluje
   SumatraPDF i mutool przez winget (kroki 2 i 3 poniżej wtedy nie są potrzebne).
2. SumatraPDF już zainstalowany (`%LOCALAPPDATA%\SumatraPDF\SumatraPDF.exe`) — skrypt PowerShell
   znajduje go automatycznie, nic więcej nie trzeba robić.
3. `mutool` (do scalania faktur w jeden plik przed drukiem) już zainstalowany przez
   `winget install ArtifexSoftware.mutool` — skrypt znajduje go automatycznie.

## Użycie

1. Zaloguj się w KSeF (https://ap.ksef.mf.gov.pl/web/invoice-list) tak jak zawsze — automat nie
   dotyka logowania.
2. Na liście faktur w prawym górnym rogu pojawi się panel "KSeF - automat pobierania". Wybierz
   zakres dat (ten miesiąc / poprzedni / następny / własny) i kliknij **Start**. Skrypt sam
   przełączy zakładkę, ustawi filtr i wierszy na stronę, zaznaczy po 10 faktur, wybierze format
   PDF, przejdzie między stronami listy (obsługuje paginację), aż pobierze wszystkie nowe faktury
   z wybranego zakresu do Downloads. Log widać na żywo w panelu.
3. Po zakończeniu ("Koniec listy faktur. Zakończono.") uruchom aplikację — dwuklik na skrót
   **"Drukuj faktury KSeF"** na Pulpicie (bez okna konsoli w tle), albo na dowolnym komputerze
   dwuklik na `Drukuj faktury KSeF.bat` w głównym folderze repo, albo w PowerShell:
   ```powershell
   powershell -ExecutionPolicy Bypass -File "c:\Users\48665\Desktop\ksef\powershell\Drukuj-Faktury.ps1"
   ```
   Otworzy się okno, które od razu synchronizuje nowe paczki .zip z Downloads do `KSEF\do druku`
   (rozpakowane) i `KSEF\zip archiwum` (oryginalne zipy), pokazuje listę oczekujących faktur oraz
   status domyślnej drukarki w prawym górnym rogu (nazwa + gotowa/drukuje/offline, na zielono
   albo na czerwono, odświeżany co 10 sekund).
   Wybierz zakres dat (na żywo widać ile faktur pasuje) i kliknij **Drukuj**. Aplikacja scali
   pasujące faktury (w kolejności dat wystawienia, dla księgowej) w jeden plik PDF, po czym
   pokaże **okno potwierdzenia** z liczbą faktur, łączną liczbą stron i szacunkową liczbą kartek
   papieru (dwustronnie) oraz status drukarki w tym momencie (z ostrzeżeniem na czerwono, jeśli
   wygląda na offline) — stamtąd możesz kliknąć **"Podgląd PDF"**, żeby otworzyć scalony plik
   w domyślnej przeglądarce PDF i sprawdzić go przed wysłaniem do drukarki, a dopiero potem
   **Drukuj** (albo **Anuluj**, jeśli coś jest nie tak — nic wtedy nie zostanie wydrukowane ani
   przeniesione, faktury zostają w `do druku` bez zmian). Po realnym druku aplikacja wysyła plik
   do drukarki jako **jedno** zadanie (dwustronnie, czarno-biało) — zamiast osobnego zadania na
   każdą fakturę, co przy większej liczbie potrafiło zapychać kolejkę wydruku — i przenosi
   oryginalne PDF-y (i scalony plik jako archiwum) do `KSEF\wydrukowane`, odświeża listę i
   pokazuje powiadomienie. Faktury spoza wybranego zakresu zostają w `do druku` na później.
   Przyciski "Otwórz 'do druku'" / "Otwórz 'wydrukowane'" otwierają odpowiedni folder w
   Eksploratorze, a "Synchronizuj z Downloads" można kliknąć ręcznie w dowolnym momencie (np. gdy
   dograłeś w przeglądarce kolejną paczkę faktur bez zamykania okna).

## Jak to rozpoznaje "już pobrane" / "już wydrukowane"

- **Pobieranie** (bookmarklet): pamięta numery KSeF pobranych faktur w `localStorage` strony,
  niezależnie od tego czy przeglądarkę zamkniesz. Licznik widoczny w panelu.
  Przycisk "Wyczyść historię" resetuje tę pamięć (np. do testów).
- **Drukowanie** (PowerShell): plik trafia do `do druku` tylko raz (sprawdzane po nazwie =
  numer KSeF, także względem `wydrukowane`, więc nie zdubluje się nawet po ponownym pobraniu
  tej samej faktury). Po wydruku PDF wędruje do `wydrukowane` i nie zostanie wydrukowany
  ponownie.

## Ograniczenia / na co uważać

- KSeF pozwala pobrać max 10 zaznaczonych faktur na raz — stąd paczkowanie po 10.
- Filtr dat i kolejność druku bazują na dacie **wystawienia** wyciągniętej z nazwy pliku PDF
  (segment RRRRMMDD w numerze KSeF, np. `...-20260831-...`). Dla faktur wystawianych online ta
  data pokrywa się z datą wystawienia; przy trybie offline mogłaby się różnić o dzień.
- Skrypt przeglądarkowy zależy od aktualnej struktury strony `ap.ksef.mf.gov.pl` (Angular
  Material). Jeśli Ministerstwo Finansów zmieni układ strony, selektory może trzeba będzie
  poprawić.
- Jeśli masz więcej niż jedną drukarkę, SumatraPDF drukuje na tej ustawionej jako domyślna
  w Windows.
- Wpisywanie zakresu dat w pola "Od"/"Do" (filtr KSeF) symuluje wpisywanie znak po znaku w pole
  z maską — jeśli KSeF zmieni sposób działania tej maski, automat może nie wpisać dat poprawnie.
  Panel wtedy pokaże ostrzeżenie w logu z aktualną zawartością pól — popraw je ręcznie, kliknij
  "Pokaż wyniki" w KSeF i uruchom Start ponownie.
- Druk jest wymuszony jako **dwustronny i czarno-biały** (`-print-settings duplex,monochrome`
  w SumatraPDF). Dwustronność działa tylko jeśli drukarka fizycznie ma duplekser — jeśli nie,
  SumatraPDF zwykle po prostu to zignoruje i wydrukuje jednostronnie (czarno-biały tryb
  powinien zadziałać na każdej drukarce).
