/*
  KSeF - automatyczne pobieranie faktur (wersja bookmarklet)

  To jest CZYTELNE źródło. Żeby zainstalować jako zakładkę w przeglądarce, użyj wygenerowanego
  pliku ksef-bookmarklet-url.txt (jedna linia zaczynająca się od "javascript:") - patrz README.

  - Trzeba kliknąć zakładkę ręcznie za każdym razem po wejściu na stronę listy faktur (nie
    wstrzykuje się automatycznie).
  - Historia pobranych faktur trzymana w localStorage strony - przetrwa zamknięcie przeglądarki.
  - Jeśli klikniesz zakładkę drugi raz, stary panel jest usuwany i tworzony od nowa (na wypadek
    przypadkowego podwójnego kliknięcia).
*/
(function () {
  'use strict';

  const existingPanel = document.getElementById('ksef-auto-panel');
  if (existingPanel) existingPanel.remove();

  const STORAGE_KEY = 'ksef_pobrane_numery';
  const BATCH_SIZE = 10;
  const DOWNLOAD_WAIT_MS = 4000;
  const CLICK_DELAY_MS = 150;
  const PAGE_WAIT_MS = 1200;
  const FILTER_WAIT_MS = 1500;
  const BUTTON_ENABLE_TIMEOUT_MS = 3000;
  const DROPDOWN_WAIT_TIMEOUT_MS = 3000;
  const TYPE_KEY_DELAY_MS = 40;

  let running = false;

  function sleep(ms) {
    return new Promise((r) => setTimeout(r, ms));
  }

  function clickEl(el) {
    el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
  }

  function loadSeen() {
    const raw = localStorage.getItem(STORAGE_KEY) || '[]';
    try {
      return new Set(JSON.parse(raw));
    } catch {
      return new Set();
    }
  }

  function saveSeen(set) {
    localStorage.setItem(STORAGE_KEY, JSON.stringify([...set]));
  }

  // --- Zakładka "Faktury zakupowe" ---
  function findTabByText(text) {
    return Array.from(document.querySelectorAll('div[role="tab"]')).find((t) => t.textContent.includes(text));
  }

  async function ensurePurchaseTab() {
    const tab = findTabByText('Faktury zakupowe');
    if (!tab) {
      log('UWAGA: nie znaleziono zakładki "Faktury zakupowe" - kontynuuję na obecnej.');
      return true;
    }
    if (tab.getAttribute('aria-selected') !== 'true') {
      clickEl(tab);
      log('Przełączono na zakładkę "Faktury zakupowe".');
      await sleep(FILTER_WAIT_MS);
    }
    return true;
  }

  // --- generyczny wybór opcji z ng-select ---
  function fireMouseSequence(el) {
    ['pointerdown', 'mousedown', 'mouseup', 'click'].forEach((type) => {
      el.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true }));
    });
  }

  function isNgSelectOpen(ngSelectEl) {
    return ngSelectEl.classList.contains('ng-select-opened');
  }

  async function findNgOption(optionText) {
    const start = Date.now();
    while (Date.now() - start < DROPDOWN_WAIT_TIMEOUT_MS) {
      const labels = Array.from(document.querySelectorAll('.ng-dropdown-panel .ng-option .ng-option-label'));
      const optionEl = labels.find((l) => l.textContent.replace(/\s+/g, ' ').trim() === optionText);
      if (optionEl) return optionEl;
      await sleep(100);
    }
    return null;
  }

  async function selectNgOption(ngSelectEl, optionText) {
    const trigger = ngSelectEl.querySelector('.ng-select-container') || ngSelectEl;

    if (!isNgSelectOpen(ngSelectEl)) fireMouseSequence(trigger);
    let optionEl = await findNgOption(optionText);

    if (!optionEl) {
      // Lista mogła się nie otworzyć za pierwszym razem (albo otworzyła i zamknęła) - spróbuj raz jeszcze.
      if (isNgSelectOpen(ngSelectEl)) fireMouseSequence(trigger);
      await sleep(200);
      fireMouseSequence(trigger);
      optionEl = await findNgOption(optionText);
    }

    if (!optionEl) {
      if (!isNgSelectOpen(ngSelectEl)) {
        log(`BŁĄD: lista rozwijana dla "${optionText}" nie chce się rozwinąć (kliknięcie nie otwiera panelu).`);
      } else {
        const seen = Array.from(document.querySelectorAll('.ng-dropdown-panel .ng-option .ng-option-label')).map((l) =>
          l.textContent.trim()
        );
        log(
          `UWAGA: nie znaleziono opcji "${optionText}" na liście rozwijanej (widoczne opcje: ${
            seen.join(', ') || 'brak'
          }).`
        );
      }
      return false;
    }
    clickEl(optionEl.closest('.ng-option'));
    await sleep(300);
    return true;
  }

  // --- rozwijanie sekcji "Filtrowanie" (domyślnie zwinięta) ---
  function getFilterExpanderHeader() {
    return (
      document.querySelector('[test-id="section_filter"] .expanded-filter__header-wrapper') ||
      document.querySelector('.expanded-filter__header-wrapper[aria-controls="form__controls-wrapper"]')
    );
  }

  async function ensureFilterExpanded() {
    const header = getFilterExpanderHeader();
    if (!header) {
      log('UWAGA: nie znaleziono nagłówka sekcji "Filtrowanie" - kontynuuję zakładając, że jest rozwinięta.');
      return true;
    }
    if (header.getAttribute('aria-expanded') !== 'true') {
      clickEl(header);
      log('Rozwinięto sekcję "Filtrowanie".');
      await sleep(FILTER_WAIT_MS);
    }
    return true;
  }

  async function ensureDateTypeIssueDate() {
    const el = document.querySelector('ng-select[formcontrolname="dateType"]');
    if (!el) {
      log('UWAGA: nie znaleziono pola "Rodzaj daty".');
      return false;
    }
    return selectNgOption(el, 'Data wystawienia');
  }

  async function ensureRowsPerPage50() {
    const el = document.querySelector('ng-select.paginator_select');
    if (!el) {
      log('UWAGA: nie znaleziono ustawienia liczby wierszy na stronę.');
      return false;
    }
    const current = el.querySelector('.ng-value-label');
    if (current && current.textContent.trim() === '50 wierszy na stronę') return true;
    const ok = await selectNgOption(el, '50 wierszy na stronę');
    if (ok) log('Ustawiono 50 wierszy na stronę.');
    return ok;
  }

  // --- wpisywanie daty w pole z maską DD.MM.RRRR ---
  function formatPl(date) {
    return `${String(date.getDate()).padStart(2, '0')}.${String(date.getMonth() + 1).padStart(2, '0')}.${date.getFullYear()}`;
  }

  async function typeMaskedDate(inputEl, date) {
    const digits =
      String(date.getDate()).padStart(2, '0') + String(date.getMonth() + 1).padStart(2, '0') + String(date.getFullYear());
    inputEl.focus();
    inputEl.value = '';
    inputEl.dispatchEvent(new Event('input', { bubbles: true }));
    await sleep(50);
    for (const ch of digits) {
      inputEl.dispatchEvent(new KeyboardEvent('keydown', { key: ch, bubbles: true, cancelable: true }));
      inputEl.value += ch;
      inputEl.dispatchEvent(new Event('input', { bubbles: true }));
      inputEl.dispatchEvent(new KeyboardEvent('keyup', { key: ch, bubbles: true, cancelable: true }));
      await sleep(TYPE_KEY_DELAY_MS);
    }
    inputEl.dispatchEvent(new Event('change', { bubbles: true }));
    inputEl.blur();
    await sleep(200);
    return inputEl.value.trim() === formatPl(date);
  }

  async function applyDateFilter(fromDate, toDate) {
    await ensureFilterExpanded();

    const dateTypeOk = await ensureDateTypeIssueDate();
    if (!dateTypeOk) return false;

    const fromInput = document.querySelector('input[formcontrolname="dateFrom"]');
    const toInput = document.querySelector('input[formcontrolname="dateTo"]');
    if (!fromInput || !toInput) {
      log('BŁĄD: nie znaleziono pól daty "Od"/"Do" w filtrze.');
      return false;
    }

    const okFrom = await typeMaskedDate(fromInput, fromDate);
    const okTo = await typeMaskedDate(toInput, toDate);
    if (!okFrom || !okTo) {
      log(
        `UWAGA: automatyczne wpisanie dat mogło się nie udać (Od: "${fromInput.value}", Do: "${toInput.value}"). ` +
          `Sprawdź pola filtru, popraw ręcznie jeśli trzeba, kliknij "Pokaż wyniki" i uruchom Start ponownie.`
      );
    }

    const showBtn = document.querySelector('[test-id="btn_show-results"]');
    if (!showBtn) {
      log('BŁĄD: nie znaleziono przycisku "Pokaż wyniki".');
      return false;
    }
    clickEl(showBtn);
    log(`Filtr zastosowany: data wystawienia ${formatPl(fromDate)} - ${formatPl(toDate)}.`);
    await sleep(FILTER_WAIT_MS);
    return true;
  }

  // --- tabela faktur ---
  function getRows() {
    return Array.from(document.querySelectorAll('tr[mat-row]'));
  }

  function rowData(row) {
    const ksefEl = row.querySelector('td.cdk-column-ksefNumber .table-component__label');
    const dateEl = row.querySelector('td.cdk-column-issueDate');
    const invEl = row.querySelector('td.cdk-column-invoiceNumber .table-cell-attachment-copy__text');
    const sellerEl = row.querySelector('td.cdk-column-sellerName');
    const ksefNumber = ksefEl ? ksefEl.textContent.trim() : null;
    if (!ksefNumber) return null;
    return {
      ksefNumber,
      issueDate: dateEl ? dateEl.textContent.trim() : '',
      invoiceNumber: invEl ? invEl.textContent.trim() : '',
      sellerName: sellerEl ? sellerEl.textContent.trim() : '',
    };
  }

  function findRowByKsef(ksefNumber) {
    return getRows().find((r) => {
      const d = rowData(r);
      return d && d.ksefNumber === ksefNumber;
    });
  }

  function getCheckbox(row) {
    return row.querySelector('td.cdk-column-checkbox [role="checkbox"]');
  }

  function isChecked(row) {
    const cb = getCheckbox(row);
    return !!cb && cb.getAttribute('aria-checked') === 'true';
  }

  async function setChecked(row, checked) {
    if (!row || isChecked(row) === checked) return;
    const cb = getCheckbox(row);
    if (!cb) return;
    clickEl(cb);
    await sleep(CLICK_DELAY_MS);
  }

  function getPobierzButton() {
    const dd = document.querySelector('akmf-dropdown[test-id="dropdown_download-invoice"]');
    if (!dd) return null;
    return dd.querySelector('button[role="combobox"]:not(.akmf-dropdown__expander-btn)');
  }

  async function waitUntilEnabled(btn, timeout) {
    const start = Date.now();
    while (btn.disabled || btn.getAttribute('aria-disabled') === 'true') {
      if (Date.now() - start > timeout) return false;
      await sleep(100);
    }
    return true;
  }

  async function clickPobierzAndChoosePdf() {
    const trigger = getPobierzButton();
    if (!trigger) {
      log('BŁĄD: nie znaleziono przycisku "Pobierz".');
      return false;
    }
    const enabled = await waitUntilEnabled(trigger, BUTTON_ENABLE_TIMEOUT_MS);
    if (!enabled) {
      log('BŁĄD: przycisk "Pobierz" pozostał nieaktywny.');
      return false;
    }
    clickEl(trigger);

    const start = Date.now();
    let pdfOption = null;
    while (Date.now() - start < DROPDOWN_WAIT_TIMEOUT_MS) {
      pdfOption = document.querySelector('[id$="-akmf-dropdownPDF"]');
      if (pdfOption) break;
      await sleep(100);
    }
    if (!pdfOption) {
      log('BŁĄD: nie pojawiła się lista formatu (PDF/XML) po kliknięciu "Pobierz".');
      return false;
    }
    clickEl(pdfOption);
    return true;
  }

  function getNextPageButton() {
    return document.querySelector('app-paginator button[aria-label="Następna strona"]');
  }

  function isNextPageDisabled(btn) {
    return !btn || btn.disabled || btn.classList.contains('custom-paginator__buttons--disabled');
  }

  // --- zakres dat: presety ---
  function startOfMonth(d) {
    return new Date(d.getFullYear(), d.getMonth(), 1);
  }
  function endOfMonth(d) {
    return new Date(d.getFullYear(), d.getMonth() + 1, 0);
  }

  function getSelectedRange() {
    const checked = panel.querySelector('input[name="ksef-range"]:checked');
    const val = checked ? checked.value : 'current';
    const today = new Date();
    if (val === 'current') return { from: startOfMonth(today), to: endOfMonth(today) };
    if (val === 'prev') {
      const d = new Date(today.getFullYear(), today.getMonth() - 1, 1);
      return { from: startOfMonth(d), to: endOfMonth(d) };
    }
    if (val === 'next') {
      const d = new Date(today.getFullYear(), today.getMonth() + 1, 1);
      return { from: startOfMonth(d), to: endOfMonth(d) };
    }
    const fromEl = panel.querySelector('#ksef-auto-from');
    const toEl = panel.querySelector('#ksef-auto-to');
    return { from: new Date(fromEl.value), to: new Date(toEl.value) };
  }

  // --- Panel UI ---
  const panel = document.createElement('div');
  panel.id = 'ksef-auto-panel';
  panel.style.cssText = `
    position: fixed; top: 80px; right: 20px; width: 340px;
    background: #fff; border: 2px solid #1a3e6f; border-radius: 8px;
    box-shadow: 0 4px 16px rgba(0,0,0,0.25); z-index: 999999;
    font-family: Arial, sans-serif; font-size: 13px; color: #222;
  `;
  const todayStr = new Date().toISOString().slice(0, 10);
  panel.innerHTML = `
    <div style="background:#1a3e6f;color:#fff;padding:8px 12px;border-radius:6px 6px 0 0;font-weight:bold;">
      KSeF - automat pobierania
    </div>
    <div style="padding:10px 12px;">
      <div style="margin-bottom:8px;">
        <label style="display:block;margin-bottom:4px;"><input type="radio" name="ksef-range" value="current" checked> Ten miesiąc</label>
        <label style="display:block;margin-bottom:4px;"><input type="radio" name="ksef-range" value="prev"> Poprzedni miesiąc</label>
        <label style="display:block;margin-bottom:4px;"><input type="radio" name="ksef-range" value="next"> Następny miesiąc</label>
        <label style="display:block;margin-bottom:4px;"><input type="radio" name="ksef-range" value="custom"> Własny zakres:</label>
        <div style="margin-left:20px;">
          <input type="date" id="ksef-auto-from" value="${todayStr}" style="width:130px;">
          -
          <input type="date" id="ksef-auto-to" value="${todayStr}" style="width:130px;">
        </div>
      </div>
      <div style="margin-bottom:8px;">Pobranych dotychczas: <b id="ksef-auto-count">0</b></div>
      <button id="ksef-auto-start" style="margin-right:6px;padding:6px 10px;">Start</button>
      <button id="ksef-auto-stop" style="margin-right:6px;padding:6px 10px;" disabled>Stop</button>
      <button id="ksef-auto-reset" style="padding:6px 10px;">Wyczyść historię</button>
      <button id="ksef-auto-close" style="padding:6px 10px;float:right;">Zamknij</button>
      <div id="ksef-auto-log" style="margin-top:10px;max-height:220px;overflow-y:auto;background:#f5f5f5;padding:6px;border-radius:4px;white-space:pre-wrap;line-height:1.4;"></div>
    </div>
  `;
  document.body.appendChild(panel);

  const logEl = panel.querySelector('#ksef-auto-log');
  const countEl = panel.querySelector('#ksef-auto-count');
  const startBtn = panel.querySelector('#ksef-auto-start');
  const stopBtn = panel.querySelector('#ksef-auto-stop');
  const resetBtn = panel.querySelector('#ksef-auto-reset');
  const closeBtn = panel.querySelector('#ksef-auto-close');

  function log(msg) {
    const time = new Date().toLocaleTimeString('pl-PL');
    logEl.textContent += `[${time}] ${msg}\n`;
    logEl.scrollTop = logEl.scrollHeight;
  }

  function updateCount() {
    countEl.textContent = loadSeen().size;
  }
  updateCount();

  resetBtn.addEventListener('click', () => {
    if (!confirm('Na pewno wyczyścić historię pobranych faktur? Automat od nowa pobierze wszystkie faktury z listy.')) return;
    saveSeen(new Set());
    updateCount();
    log('Historia wyczyszczona.');
  });

  closeBtn.addEventListener('click', () => {
    running = false;
    panel.remove();
  });

  stopBtn.addEventListener('click', () => {
    running = false;
    log('Zatrzymywanie...');
  });

  startBtn.addEventListener('click', () => {
    if (running) return;
    running = true;
    startBtn.disabled = true;
    stopBtn.disabled = false;
    runAutomation()
      .catch((err) => log(`BŁĄD: ${err && err.message ? err.message : err}`))
      .finally(() => {
        running = false;
        startBtn.disabled = false;
        stopBtn.disabled = true;
      });
  });

  async function runAutomation() {
    log('Start.');

    const range = getSelectedRange();
    log(`Zakres dat wystawienia: ${formatPl(range.from)} - ${formatPl(range.to)}.`);

    await ensurePurchaseTab();

    const filterOk = await applyDateFilter(range.from, range.to);
    if (!filterOk) {
      running = false;
      return;
    }

    await ensureRowsPerPage50();
    await sleep(FILTER_WAIT_MS);

    const seen = loadSeen();
    let pageIndex = 1;

    while (running) {
      const rows = getRows().map(rowData).filter(Boolean);
      const pending = rows.filter((r) => !seen.has(r.ksefNumber));
      log(`Strona ${pageIndex}: ${rows.length} wierszy, ${pending.length} do pobrania.`);

      while (pending.length > 0 && running) {
        const batch = pending.splice(0, BATCH_SIZE);

        for (const item of batch) {
          const row = findRowByKsef(item.ksefNumber);
          await setChecked(row, true);
        }

        const clicked = await clickPobierzAndChoosePdf();
        if (!clicked) {
          running = false;
          break;
        }

        const dates = batch.map((b) => b.issueDate).join(', ');
        log(`Pobrano paczkę ${batch.length} faktur: ${dates}`);
        await sleep(DOWNLOAD_WAIT_MS);

        for (const item of batch) {
          seen.add(item.ksefNumber);
          const row = findRowByKsef(item.ksefNumber);
          await setChecked(row, false);
        }
        saveSeen(seen);
        updateCount();
        await sleep(400);
      }

      if (!running) break;

      const nextBtn = getNextPageButton();
      if (isNextPageDisabled(nextBtn)) {
        log('Koniec listy faktur. Zakończono.');
        break;
      }
      clickEl(nextBtn);
      pageIndex++;
      await sleep(PAGE_WAIT_MS);
    }

    log('Automat zatrzymany.');
  }
})();
