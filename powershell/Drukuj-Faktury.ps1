<#
    Aplikacja (okno WinForms) do drukowania faktur z KSeF w wybranym zakresie dat,
    w kolejności dat wystawienia, jako jedno zadanie druku.

    Struktura folderów (Pulpit\KSEF):
      KSEF\do druku      - PDF-y oczekujące na wydruk (wypakowane z paczek .zip z Downloads)
      KSEF\wydrukowane   - PDF-y już wydrukowane + archiwum scalonych plików wysłanych do druku
      KSEF\zip archiwum  - oryginalne paczki .zip z Downloads (kopia zapasowa)
      KSEF\log.txt       - historia działania (przydatna gdy okno się zamknie po błędzie)

    Uruchamiaj po zakończeniu pobierania w przeglądarce (bookmarklet
    ksef-auto-pobieranie-bookmarklet.js). Po starcie okno samo synchronizuje nowe paczki .zip
    z Downloads do "do druku". Wybierz zakres dat i kliknij "Drukuj" - skrypt scali pasujące
    faktury w jeden plik PDF (dopełniając nieparzyste faktury pustą stroną, żeby przy druku
    dwustronnym żadna faktura nie skleiła się z sąsiednią na jednej kartce) i wydrukuje go
    jako jedno zadanie druku (dwustronnie, czarno-biało), po czym przeniesie faktury do
    "wydrukowane".

    Wymaga: SumatraPDF (winget install SumatraPDF.SumatraPDF) i mutool
    (winget install ArtifexSoftware.mutool).
#>

param(
    [string]$DownloadsFolder = "$env:USERPROFILE\Downloads",
    [string]$KsefRoot = "$env:USERPROFILE\Desktop\KSEF",
    [string]$SumatraPath,
    [string]$MutoolPath,
    [int]$PostPrintWaitMs = 3000
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Show-FatalError {
    param([string]$Message)
    [System.Windows.Forms.MessageBox]::Show($Message, 'KSeF - błąd', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    exit 1
}

if (-not $SumatraPath) {
    $candidates = @(
        (Join-Path $PSScriptRoot 'SumatraPDF.exe'),
        "$env:LOCALAPPDATA\SumatraPDF\SumatraPDF.exe",
        "$env:ProgramFiles\SumatraPDF\SumatraPDF.exe",
        "${env:ProgramFiles(x86)}\SumatraPDF\SumatraPDF.exe"
    )
    $SumatraPath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $SumatraPath -or -not (Test-Path $SumatraPath)) {
    Show-FatalError "Nie znaleziono SumatraPDF.exe.`n`nZainstaluj: winget install SumatraPDF.SumatraPDF`nalbo wskaż plik parametrem -SumatraPath."
}

if (-not $MutoolPath) {
    $wingetPkg = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Filter 'ArtifexSoftware.mutool_*' -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($wingetPkg) {
        $found = Get-ChildItem -Path $wingetPkg.FullName -Filter 'mutool.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $MutoolPath = $found.FullName }
    }
    if (-not $MutoolPath) {
        $cmd = Get-Command mutool -ErrorAction SilentlyContinue
        if ($cmd) { $MutoolPath = $cmd.Source }
    }
}
if (-not $MutoolPath -or -not (Test-Path $MutoolPath)) {
    Show-FatalError "Nie znaleziono mutool.exe (do scalania PDF w jedno zadanie druku).`n`nZainstaluj: winget install ArtifexSoftware.mutool`nalbo wskaż plik parametrem -MutoolPath."
}

$doDrukuFolder = Join-Path $KsefRoot 'do druku'
$wydrukowaneFolder = Join-Path $KsefRoot 'wydrukowane'
$zipArchiwumFolder = Join-Path $KsefRoot 'zip archiwum'
New-Item -ItemType Directory -Force -Path $doDrukuFolder, $wydrukowaneFolder, $zipArchiwumFolder | Out-Null

$logFile = Join-Path $KsefRoot 'log.txt'
$ksefPattern = '^(\d+)-(\d{8})-([0-9A-Fa-f]+)-([0-9A-Za-z]{2})\.pdf$'

$script:logBox = $null

function Write-Log {
    param([string]$Message)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    if ($script:logBox) {
        $script:logBox.AppendText("$line`r`n")
        $script:logBox.SelectionStart = $script:logBox.Text.Length
        $script:logBox.ScrollToCaret()
    }
    [System.Windows.Forms.Application]::DoEvents()
}

# --- synchronizacja nowych paczek .zip i pojedynczych PDF z Downloads do "do druku" ---
function Sync-Downloads {
    if (-not (Test-Path $DownloadsFolder)) {
        Write-Log "UWAGA: folder Downloads nie istnieje: $DownloadsFolder - pomijam synchronizację."
        return
    }

    # pojedyncze PDF-y faktur pobrane bez paczki .zip (tylko z nazwą w formacie KSeF)
    $loosePdfs = @(Get-ChildItem -Path $DownloadsFolder -Filter '*.pdf' -File | Where-Object { $_.Name -match $ksefPattern })
    foreach ($pdf in $loosePdfs) {
        $target = Join-Path $doDrukuFolder $pdf.Name
        if ((Test-Path $target) -or (Test-Path (Join-Path $wydrukowaneFolder $pdf.Name))) {
            Write-Log "Pojedynczy PDF $($pdf.Name): już był pobrany wcześniej - pomijam (zostaje w Downloads)."
            continue
        }
        try {
            Move-Item -Path $pdf.FullName -Destination $target -Force
            Write-Log "Zaimportowano pojedynczy PDF $($pdf.Name) -> 'do druku'."
        } catch {
            Write-Log "UWAGA: nie udało się przenieść $($pdf.Name): $_"
        }
    }

    $zipFiles = @(Get-ChildItem -Path $DownloadsFolder -Filter '*.zip' -File)
    if ($zipFiles.Count -eq 0) {
        Write-Log 'Synchronizacja: brak nowych paczek .zip w Downloads.'
        return
    }

    $workFolder = Join-Path $env:TEMP 'ksef_sync_tmp'
    if (Test-Path $workFolder) { Remove-Item $workFolder -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $workFolder | Out-Null

    foreach ($zip in $zipFiles) {
        $extractDir = Join-Path $workFolder $zip.BaseName
        try {
            Expand-Archive -Path $zip.FullName -DestinationPath $extractDir -Force
        } catch {
            Write-Log "UWAGA: nie udało się rozpakować $($zip.Name): $_"
            continue
        }

        $matched = Get-ChildItem -Path $extractDir -Filter '*.pdf' -File | Where-Object { $_.Name -match $ksefPattern }
        if ($matched.Count -eq 0) {
            Write-Log "Pomijam $($zip.Name) - nie wygląda na paczkę faktur KSeF."
            continue
        }

        $added = 0
        foreach ($pdf in $matched) {
            $target = Join-Path $doDrukuFolder $pdf.Name
            $already = (Test-Path $target) -or (Test-Path (Join-Path $wydrukowaneFolder $pdf.Name))
            if (-not $already) {
                Copy-Item -Path $pdf.FullName -Destination $target -Force
                $added++
            }
        }

        $zipDest = Join-Path $zipArchiwumFolder $zip.Name
        if (Test-Path $zipDest) {
            $zipDest = Join-Path $zipArchiwumFolder ("{0}_{1}{2}" -f $zip.BaseName, (Get-Date -Format 'yyyyMMdd_HHmmss'), $zip.Extension)
        }
        Move-Item -Path $zip.FullName -Destination $zipDest -Force
        Write-Log "Zsynchronizowano $($zip.Name): $added nowych faktur -> 'do druku' (zip -> 'zip archiwum')."
    }
    Remove-Item $workFolder -Recurse -Force
}

function Get-PendingInvoices {
    Get-ChildItem -Path $doDrukuFolder -Filter '*.pdf' -File |
        Where-Object { $_.Name -match $ksefPattern } |
        ForEach-Object {
            $null = $_.Name -match $ksefPattern
            [PSCustomObject]@{
                Path       = $_.FullName
                Name       = $_.Name
                KsefNumber = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
                Date       = [datetime]::ParseExact($Matches[2], 'yyyyMMdd', $null)
            }
        } | Sort-Object Date
}

# ============================= Okno aplikacji =============================

$form = New-Object System.Windows.Forms.Form
$form.Text = 'KSeF - drukowanie faktur'
$form.Size = New-Object System.Drawing.Size(660, 700)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(660, 700)

$countLabel = New-Object System.Windows.Forms.Label
$countLabel.Text = "Faktur oczekujących w 'do druku': 0"
$countLabel.Location = New-Object System.Drawing.Point(15, 15)
$countLabel.Size = New-Object System.Drawing.Size(280, 20)
$countLabel.Font = New-Object System.Drawing.Font($countLabel.Font, [System.Drawing.FontStyle]::Bold)

$printerLabel = New-Object System.Windows.Forms.Label
$printerLabel.Text = 'Drukarka: sprawdzam...'
$printerLabel.Location = New-Object System.Drawing.Point(300, 15)
$printerLabel.Size = New-Object System.Drawing.Size(330, 20)
$printerLabel.TextAlign = 'MiddleRight'
$printerLabel.Anchor = 'Top,Right'
$printerLabel.Font = New-Object System.Drawing.Font($printerLabel.Font, [System.Drawing.FontStyle]::Bold)

$listView = New-Object System.Windows.Forms.ListView
$listView.View = 'Details'
$listView.FullRowSelect = $true
$listView.GridLines = $true
$listView.Location = New-Object System.Drawing.Point(15, 40)
$listView.Size = New-Object System.Drawing.Size(615, 200)
$listView.Anchor = 'Top,Bottom,Left,Right'
$listView.Columns.Add('Data wystawienia', 140) | Out-Null
$listView.Columns.Add('Numer KSeF', 440) | Out-Null

$groupBox = New-Object System.Windows.Forms.GroupBox
$groupBox.Text = 'Zakres dat do druku'
$groupBox.Location = New-Object System.Drawing.Point(15, 250)
$groupBox.Size = New-Object System.Drawing.Size(615, 145)
$groupBox.Anchor = 'Top,Left,Right'

$today = Get-Date
$currentMonthStart = Get-Date -Year $today.Year -Month $today.Month -Day 1
$pl = [System.Globalization.CultureInfo]::GetCultureInfo('pl-PL')

function Get-MonthLabel {
    param([datetime]$Start)
    $end = $Start.AddMonths(1).AddDays(-1)
    '{0} ({1:dd.MM} - {2:dd.MM.yyyy})' -f $Start.ToString('MMMM yyyy', $pl), $Start, $end
}

$radioCurrent = New-Object System.Windows.Forms.RadioButton
$radioCurrent.Text = "Ten miesiąc - $(Get-MonthLabel $currentMonthStart)"
$radioCurrent.Location = New-Object System.Drawing.Point(15, 20)
$radioCurrent.Size = New-Object System.Drawing.Size(580, 20)
$radioCurrent.Checked = $true

$radioPrev = New-Object System.Windows.Forms.RadioButton
$radioPrev.Text = "Poprzedni miesiąc - $(Get-MonthLabel $currentMonthStart.AddMonths(-1))"
$radioPrev.Location = New-Object System.Drawing.Point(15, 42)
$radioPrev.Size = New-Object System.Drawing.Size(580, 20)

$radioNext = New-Object System.Windows.Forms.RadioButton
$radioNext.Text = "Następny miesiąc - $(Get-MonthLabel $currentMonthStart.AddMonths(1))"
$radioNext.Location = New-Object System.Drawing.Point(15, 64)
$radioNext.Size = New-Object System.Drawing.Size(580, 20)

$radioCustom = New-Object System.Windows.Forms.RadioButton
$radioCustom.Text = 'Własny zakres:'
$radioCustom.Location = New-Object System.Drawing.Point(15, 86)
$radioCustom.Size = New-Object System.Drawing.Size(110, 20)

$dateFrom = New-Object System.Windows.Forms.DateTimePicker
$dateFrom.Format = 'Short'
$dateFrom.Location = New-Object System.Drawing.Point(130, 84)
$dateFrom.Size = New-Object System.Drawing.Size(110, 20)
$dateFrom.Value = $currentMonthStart
$dateFrom.Enabled = $false

$labelTo = New-Object System.Windows.Forms.Label
$labelTo.Text = '-'
$labelTo.Location = New-Object System.Drawing.Point(248, 87)
$labelTo.Size = New-Object System.Drawing.Size(12, 20)

$dateTo = New-Object System.Windows.Forms.DateTimePicker
$dateTo.Format = 'Short'
$dateTo.Location = New-Object System.Drawing.Point(265, 84)
$dateTo.Size = New-Object System.Drawing.Size(110, 20)
$dateTo.Value = $today
$dateTo.Enabled = $false

$rangeCountLabel = New-Object System.Windows.Forms.Label
$rangeCountLabel.Text = "Do wydruku w wybranym zakresie: 0"
$rangeCountLabel.Location = New-Object System.Drawing.Point(15, 115)
$rangeCountLabel.Size = New-Object System.Drawing.Size(580, 20)
$rangeCountLabel.Font = New-Object System.Drawing.Font($rangeCountLabel.Font, [System.Drawing.FontStyle]::Bold)

$groupBox.Controls.AddRange(@($radioCurrent, $radioPrev, $radioNext, $radioCustom, $dateFrom, $labelTo, $dateTo, $rangeCountLabel))

$syncButton = New-Object System.Windows.Forms.Button
$syncButton.Text = 'Synchronizuj z Downloads'
$syncButton.Location = New-Object System.Drawing.Point(15, 405)
$syncButton.Size = New-Object System.Drawing.Size(170, 30)
$syncButton.Anchor = 'Top,Left'

$openDoDrukuButton = New-Object System.Windows.Forms.Button
$openDoDrukuButton.Text = "Otwórz 'do druku'"
$openDoDrukuButton.Location = New-Object System.Drawing.Point(195, 405)
$openDoDrukuButton.Size = New-Object System.Drawing.Size(140, 30)
$openDoDrukuButton.Anchor = 'Top,Left'

$openWydrukowaneButton = New-Object System.Windows.Forms.Button
$openWydrukowaneButton.Text = "Otwórz 'wydrukowane'"
$openWydrukowaneButton.Location = New-Object System.Drawing.Point(345, 405)
$openWydrukowaneButton.Size = New-Object System.Drawing.Size(150, 30)
$openWydrukowaneButton.Anchor = 'Top,Left'

$printButton = New-Object System.Windows.Forms.Button
$printButton.Text = 'Drukuj'
$printButton.Location = New-Object System.Drawing.Point(505, 405)
$printButton.Size = New-Object System.Drawing.Size(125, 30)
$printButton.Anchor = 'Top,Right'
$printButton.Font = New-Object System.Drawing.Font($printButton.Font, [System.Drawing.FontStyle]::Bold)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(15, 445)
$progressBar.Size = New-Object System.Drawing.Size(615, 20)
$progressBar.Anchor = 'Top,Left,Right'

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = 'Gotowe.'
$statusLabel.Location = New-Object System.Drawing.Point(15, 470)
$statusLabel.Size = New-Object System.Drawing.Size(615, 20)
$statusLabel.Anchor = 'Top,Left,Right'

$logBoxCtrl = New-Object System.Windows.Forms.TextBox
$logBoxCtrl.Multiline = $true
$logBoxCtrl.ReadOnly = $true
$logBoxCtrl.ScrollBars = 'Vertical'
$logBoxCtrl.Location = New-Object System.Drawing.Point(15, 495)
$logBoxCtrl.Size = New-Object System.Drawing.Size(615, 155)
$logBoxCtrl.Anchor = 'Top,Bottom,Left,Right'
$logBoxCtrl.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$script:logBox = $logBoxCtrl

$form.Controls.AddRange(@($countLabel, $printerLabel, $listView, $groupBox, $syncButton, $openDoDrukuButton, $openWydrukowaneButton, $printButton, $progressBar, $statusLabel, $logBoxCtrl))

function Get-DefaultPrinterInfo {
    try {
        $printer = Get-CimInstance -ClassName Win32_Printer -ErrorAction Stop | Where-Object { $_.Default } | Select-Object -First 1
        if (-not $printer) {
            return @{ Name = 'brak domyślnej drukarki'; StatusText = ''; Ok = $false }
        }
        $statusMap = @{ 1 = 'inny'; 2 = 'nieznany'; 3 = 'gotowa'; 4 = 'drukuje'; 5 = 'rozgrzewa się'; 6 = 'zatrzymana'; 7 = 'offline' }
        $statusText = $statusMap[[int]$printer.PrinterStatus]
        if (-not $statusText) { $statusText = "kod $($printer.PrinterStatus)" }
        $offline = [bool]$printer.WorkOffline -or ([int]$printer.PrinterStatus -eq 7)
        if ($offline) { $statusText = 'offline' }
        return @{ Name = $printer.Name; StatusText = $statusText; Ok = (-not $offline) }
    } catch {
        return @{ Name = 'błąd odczytu statusu'; StatusText = ''; Ok = $false }
    }
}

function Update-PrinterStatus {
    try {
        $info = Get-DefaultPrinterInfo
        $text = if ($info.StatusText) { "Drukarka: $($info.Name) ($($info.StatusText))" } else { "Drukarka: $($info.Name)" }
        $printerLabel.Text = $text
        $printerLabel.ForeColor = if ($info.Ok) { [System.Drawing.Color]::DarkGreen } else { [System.Drawing.Color]::DarkRed }
        return $info
    } catch {
        $printerLabel.Text = 'Drukarka: nie udało się sprawdzić'
        $printerLabel.ForeColor = [System.Drawing.Color]::DarkRed
        return @{ Name = 'nieznana'; StatusText = ''; Ok = $false }
    }
}

$printerTimer = New-Object System.Windows.Forms.Timer
$printerTimer.Interval = 10000
$printerTimer.Add_Tick({
    try { Update-PrinterStatus | Out-Null } catch { Write-Log "UWAGA: błąd odświeżania statusu drukarki: $_" }
})
$printerTimer.Start()
$form.Add_FormClosed({ $printerTimer.Stop() })

$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon = [System.Drawing.SystemIcons]::Information
$notifyIcon.Text = 'KSeF - drukowanie faktur'
$notifyIcon.Visible = $true

function Show-Balloon {
    param([string]$Text)
    $notifyIcon.BalloonTipTitle = 'KSeF'
    $notifyIcon.BalloonTipText = $Text
    $notifyIcon.ShowBalloonTip(4000)
}

$form.Add_FormClosed({ $notifyIcon.Visible = $false; $notifyIcon.Dispose() })

function Set-UIEnabled {
    param([bool]$Enabled)
    $syncButton.Enabled = $Enabled
    $printButton.Enabled = $Enabled
    $radioCurrent.Enabled = $Enabled
    $radioPrev.Enabled = $Enabled
    $radioNext.Enabled = $Enabled
    $radioCustom.Enabled = $Enabled
    $dateFrom.Enabled = $Enabled -and $radioCustom.Checked
    $dateTo.Enabled = $Enabled -and $radioCustom.Checked
}

function Get-SelectedRange {
    if ($radioPrev.Checked) {
        $d = $currentMonthStart.AddMonths(-1)
        return @{ From = $d; To = $d.AddMonths(1).AddDays(-1) }
    }
    if ($radioNext.Checked) {
        $d = $currentMonthStart.AddMonths(1)
        return @{ From = $d; To = $d.AddMonths(1).AddDays(-1) }
    }
    if ($radioCustom.Checked) {
        return @{ From = $dateFrom.Value.Date; To = $dateTo.Value.Date }
    }
    # Domyślnie (także gdy przez pomyłkę żaden radio nie jest zaznaczony): bieżący miesiąc.
    return @{ From = $currentMonthStart; To = $currentMonthStart.AddMonths(1).AddDays(-1) }
}

function Update-RangeCount {
    $range = Get-SelectedRange
    $inRange = @($script:pending | Where-Object { $_.Date.Date -ge $range.From.Date -and $_.Date.Date -le $range.To.Date })
    $rangeCountLabel.Text = "Do wydruku w wybranym zakresie ($($range.From.ToString('dd.MM.yyyy')) - $($range.To.ToString('dd.MM.yyyy'))): $($inRange.Count)"
}

function Refresh-Pending {
    $script:pending = @(Get-PendingInvoices)
    $listView.BeginUpdate()
    $listView.Items.Clear()
    foreach ($inv in $script:pending) {
        $li = New-Object System.Windows.Forms.ListViewItem($inv.Date.ToString('yyyy-MM-dd'))
        $li.SubItems.Add($inv.KsefNumber) | Out-Null
        $listView.Items.Add($li) | Out-Null
    }
    $listView.EndUpdate()
    $countLabel.Text = "Faktur oczekujących w 'do druku': $($script:pending.Count)"
    Update-RangeCount
}

$onCustomToggle = {
    $enable = $radioCustom.Checked
    $dateFrom.Enabled = $enable
    $dateTo.Enabled = $enable
    Update-RangeCount
}
$radioCurrent.Add_CheckedChanged($onCustomToggle)
$radioPrev.Add_CheckedChanged($onCustomToggle)
$radioNext.Add_CheckedChanged($onCustomToggle)
$radioCustom.Add_CheckedChanged($onCustomToggle)

# Wymuszenie stanu początkowego - dodanie RadioButtonów do kontenera po ustawieniu .Checked
# potrafi zresetować zaznaczenie, więc ustawiamy je ponownie już po podpięciu handlerów.
$radioCurrent.Checked = $true
$dateFrom.Add_ValueChanged({ Update-RangeCount })
$dateTo.Add_ValueChanged({ Update-RangeCount })

$syncButton.Add_Click({
    Set-UIEnabled $false
    $statusLabel.Text = 'Synchronizuję z Downloads...'
    try {
        Sync-Downloads
        Refresh-Pending
        $statusLabel.Text = 'Gotowe.'
    } catch {
        Write-Log "BŁĄD podczas synchronizacji: $_"
        $statusLabel.Text = 'Błąd synchronizacji - patrz log.'
        [System.Windows.Forms.MessageBox]::Show("Wystąpił błąd podczas synchronizacji:`n$_", 'KSeF - błąd', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } finally {
        Set-UIEnabled $true
    }
})

$openDoDrukuButton.Add_Click({ Start-Process explorer.exe $doDrukuFolder })
$openWydrukowaneButton.Add_Click({ Start-Process explorer.exe $wydrukowaneFolder })

function Show-PrintConfirmDialog {
    param(
        [int]$InvoiceCount,
        [int]$TotalPages,
        [int]$Sheets,
        [string]$MergedPdfPath,
        [datetime]$RangeFrom,
        [datetime]$RangeTo,
        [hashtable]$PrinterInfo
    )

    $extraHeight = 0
    if (-not $PrinterInfo.Ok) { $extraHeight = 26 }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Potwierdź druk'
    $dlg.Size = New-Object System.Drawing.Size(420, (210 + $extraHeight))
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $info = New-Object System.Windows.Forms.Label
    $info.Text = (
        "Zakres: $($RangeFrom.ToString('dd.MM.yyyy')) - $($RangeTo.ToString('dd.MM.yyyy'))`r`n" +
        "Faktur: $InvoiceCount`r`n" +
        "Stron łącznie: $TotalPages`r`n" +
        "Szacunkowo kartek papieru (dwustronnie): ok. $Sheets`r`n" +
        "Drukarka: $($PrinterInfo.Name)$(if ($PrinterInfo.StatusText) { " ($($PrinterInfo.StatusText))" })"
    )
    $info.Location = New-Object System.Drawing.Point(20, 20)
    $info.Size = New-Object System.Drawing.Size(370, 100)

    $warnLabel = $null
    $buttonsY = 120
    if (-not $PrinterInfo.Ok) {
        $warnLabel = New-Object System.Windows.Forms.Label
        $warnLabel.Text = 'UWAGA: drukarka może być offline lub niedostępna.'
        $warnLabel.ForeColor = [System.Drawing.Color]::DarkRed
        $warnLabel.Location = New-Object System.Drawing.Point(20, 120)
        $warnLabel.Size = New-Object System.Drawing.Size(370, 20)
        $buttonsY = 146
    }

    $previewButton = New-Object System.Windows.Forms.Button
    $previewButton.Text = 'Podgląd PDF'
    $previewButton.Location = New-Object System.Drawing.Point(20, $buttonsY)
    $previewButton.Size = New-Object System.Drawing.Size(110, 32)
    $previewButton.Add_Click({ Start-Process -FilePath $MergedPdfPath }.GetNewClosure())

    $printBtn = New-Object System.Windows.Forms.Button
    $printBtn.Text = 'Drukuj'
    $printBtn.Location = New-Object System.Drawing.Point(180, $buttonsY)
    $printBtn.Size = New-Object System.Drawing.Size(100, 32)
    $printBtn.DialogResult = [System.Windows.Forms.DialogResult]::Yes

    $cancelBtn = New-Object System.Windows.Forms.Button
    $cancelBtn.Text = 'Anuluj'
    $cancelBtn.Location = New-Object System.Drawing.Point(290, $buttonsY)
    $cancelBtn.Size = New-Object System.Drawing.Size(100, 32)
    $cancelBtn.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $controls = @($info, $previewButton, $printBtn, $cancelBtn)
    if ($warnLabel) { $controls += $warnLabel }
    $dlg.Controls.AddRange($controls)
    $dlg.AcceptButton = $printBtn
    $dlg.CancelButton = $cancelBtn

    $result = $dlg.ShowDialog($form)
    $dlg.Dispose()

    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) { return 'print' }
    return 'cancel'
}

$printButton.Add_Click({
    $range = Get-SelectedRange
    $sorted = @($script:pending | Where-Object { $_.Date.Date -ge $range.From.Date -and $_.Date.Date -le $range.To.Date })

    if ($sorted.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Brak faktur w wybranym zakresie dat.', 'KSeF', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }

    Set-UIEnabled $false
    $progressBar.Maximum = $sorted.Count + 2
    $progressBar.Value = 0
    $statusLabel.Text = "Przygotowuję $($sorted.Count) faktur do podglądu..."
    Write-Log "Przygotowuję do druku $($sorted.Count) faktur ($($range.From.ToString('yyyy-MM-dd')) - $($range.To.ToString('yyyy-MM-dd')))."

    # Unikalna nazwa za każdym razem - jeśli poprzedni podgląd PDF jest wciąż otwarty
    # w przeglądarce (plik zablokowany), nowe zadanie i tak może bezpiecznie ruszyć.
    $mergeWorkFolder = Join-Path $env:TEMP ('ksef_merge_tmp_' + (Get-Date -Format 'yyyyMMdd_HHmmssfff'))
    try {
        New-Item -ItemType Directory -Force -Path $mergeWorkFolder | Out-Null

        $blankPageTxt = Join-Path $mergeWorkFolder 'blank.txt'
        Set-Content -Path $blankPageTxt -Value '%%MediaBox 0 0 595 842' -Encoding ASCII
        $blankPdf = Join-Path $mergeWorkFolder 'blank.pdf'
        & $MutoolPath create -o $blankPdf $blankPageTxt | Out-Null

        $mergeArgs = @()
        foreach ($item in $sorted) {
            $pageCount = 0
            $infoOutput = & $MutoolPath info $item.Path 2>$null
            foreach ($line in $infoOutput) {
                if ($line -match 'Pages:\s*(\d+)') { $pageCount = [int]$Matches[1]; break }
            }
            $mergeArgs += $item.Path
            if ($pageCount % 2 -ne 0) { $mergeArgs += $blankPdf }
            $progressBar.Value = [Math]::Min($progressBar.Value + 1, $progressBar.Maximum)
            [System.Windows.Forms.Application]::DoEvents()
        }

        $mergedPdf = Join-Path $mergeWorkFolder 'do_wydruku.pdf'
        & $MutoolPath merge -o $mergedPdf @mergeArgs
        if (-not (Test-Path $mergedPdf)) {
            throw 'Nie udało się scalić faktur w jeden plik do druku.'
        }
        $progressBar.Value = [Math]::Min($progressBar.Value + 1, $progressBar.Maximum)

        $totalPages = 0
        $infoOutput = & $MutoolPath info $mergedPdf 2>$null
        foreach ($line in $infoOutput) {
            if ($line -match 'Pages:\s*(\d+)') { $totalPages = [int]$Matches[1]; break }
        }
        $sheets = [Math]::Ceiling($totalPages / 2.0)

        $statusLabel.Text = 'Czekam na potwierdzenie...'
        $printerInfo = Update-PrinterStatus
        [System.Windows.Forms.Application]::DoEvents()
        $decision = Show-PrintConfirmDialog -InvoiceCount $sorted.Count -TotalPages $totalPages -Sheets $sheets -MergedPdfPath $mergedPdf -RangeFrom $range.From -RangeTo $range.To -PrinterInfo $printerInfo

        if ($decision -ne 'print') {
            Write-Log 'Anulowano drukowanie (użytkownik odrzucił potwierdzenie po podglądzie).'
            $statusLabel.Text = 'Anulowano.'
            return
        }

        $statusLabel.Text = 'Wysyłam do drukarki...'
        Write-Log "Drukuję $($sorted.Count) faktur ($totalPages stron, ok. $sheets kartek) jako jedno zadanie druku."
        [System.Windows.Forms.Application]::DoEvents()

        & $SumatraPath -print-to-default -print-settings 'duplex,monochrome' -silent $mergedPdf
        Start-Sleep -Milliseconds $PostPrintWaitMs
        $progressBar.Value = $progressBar.Maximum

        $mergedArchiveName = 'scalone_{0}_{1}-{2}.pdf' -f (Get-Date -Format 'yyyyMMdd_HHmmss'), $range.From.ToString('yyyyMMdd'), $range.To.ToString('yyyyMMdd')
        Move-Item -Path $mergedPdf -Destination (Join-Path $wydrukowaneFolder $mergedArchiveName) -Force

        foreach ($item in $sorted) {
            Move-Item -Path $item.Path -Destination (Join-Path $wydrukowaneFolder $item.Name) -Force
        }

        Write-Log "Wydrukowano $($sorted.Count) faktur jako jedno zadanie druku. Archiwum: $mergedArchiveName"
        $statusLabel.Text = "Wydrukowano $($sorted.Count) faktur."
        [System.Media.SystemSounds]::Asterisk.Play()
        Show-Balloon "Wydrukowano $($sorted.Count) faktur ($($range.From.ToString('dd.MM.yyyy')) - $($range.To.ToString('dd.MM.yyyy')))."
    } catch {
        Write-Log "BŁĄD podczas drukowania: $_"
        [System.Windows.Forms.MessageBox]::Show("Wystąpił błąd podczas drukowania:`n$_", 'KSeF - błąd', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        $statusLabel.Text = 'Błąd - patrz log.'
    } finally {
        if (Test-Path $mergeWorkFolder) { Remove-Item $mergeWorkFolder -Recurse -Force -ErrorAction SilentlyContinue }
        Refresh-Pending
        Set-UIEnabled $true
    }
})

$form.Add_Shown({
    try {
        Update-PrinterStatus | Out-Null
        $statusLabel.Text = 'Synchronizuję z Downloads...'
        Write-Log 'Uruchomiono aplikację.'
        Sync-Downloads
        Refresh-Pending
        $statusLabel.Text = 'Gotowe.'
    } catch {
        Write-Log "BŁĄD podczas uruchamiania: $_"
        $statusLabel.Text = 'Błąd przy starcie - patrz log.'
        [System.Windows.Forms.MessageBox]::Show("Wystąpił błąd podczas uruchamiania aplikacji:`n$_", 'KSeF - błąd', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
})

[void]$form.ShowDialog()
