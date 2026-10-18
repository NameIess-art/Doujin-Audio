param(
    [string]$Device = '',
    [ValidateSet('page-transitions', 'core', 'library-large', 'asmr-large', 'interaction-overlap')]
    [string]$Scenario = 'page-transitions',
    [ValidateSet('baseline', 'idle', 'os-resume', 'resume', 'memory-pressure')]
    [string]$Condition = 'baseline',
    [ValidateRange(0, 2147483647)][int]$IdleSeconds = 60,
    [ValidateRange(1, 2147483647)][int]$Openings = 3,
    [switch]$Playing,
    [switch]$ProductionStartup,
    [switch]$GeneratedCovers,
    [ValidateRange(1, 2147483647)][int]$LibraryItems = 100,
    [ValidateRange(1, 2147483647)][int]$AsmrItems = 100,
    [ValidateRange(0, 2147483647)][int]$AsmrTracks = 0,
    [string]$ApkPath = '',
    [ValidatePattern('^[A-Za-z0-9_-]+$')][string]$Label = 'navigation',
    [string]$OutputDirectory = (Join-Path $env:TEMP 'audio-navigation-profile')
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if ($Playing -and $ProductionStartup) { throw 'Choose either Playing or ProductionStartup.' }
if (($Playing -or $ProductionStartup) -and $Scenario -ne 'page-transitions') { throw 'Playing and ProductionStartup require page-transitions.' }
if ($Scenario -ne 'page-transitions' -and ($Condition -ne 'baseline' -or $Openings -ne 3)) { throw 'Scroll scenarios require baseline and Openings=3.' }
if ($ProductionStartup -and ($Condition -ne 'baseline' -or $Openings -ne 1)) { throw 'Production startup requires baseline and Openings=1.' }
if ($ProductionStartup -or $Scenario -ne 'page-transitions') { $IdleSeconds = 0 }
if (!$PSBoundParameters.ContainsKey('LibraryItems') -and $Scenario -eq 'library-large') { $LibraryItems = 10000 }
if (!$PSBoundParameters.ContainsKey('AsmrItems') -and $Scenario -eq 'asmr-large') { $AsmrItems = 2000 }
if (!$PSBoundParameters.ContainsKey('AsmrTracks') -and $Scenario -eq 'asmr-large') { $AsmrTracks = 2000 }
$previousOutputs = @(Get-ChildItem -LiteralPath $OutputDirectory -File | Where-Object {
    ($_.Name -eq "$Label.json" -or $_.Name.StartsWith("$Label-")) -and
    $_.Extension -in @('.json', '.jsonl', '.txt') -and
    $_.Name -notin @("$Label-source-hashes.json", "$Label-build.txt", "$Label-host.txt")
})
if ($previousOutputs.Count) {
    $archiveDirectory = Join-Path $OutputDirectory "$Label-previous-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $archiveDirectory | Out-Null
    foreach ($output in $previousOutputs) {
        Move-Item -LiteralPath $output.FullName -Destination (Join-Path $archiveDirectory $output.Name)
    }
}
$scenario = if ($ProductionStartup) { 'page-transitions-startup' } elseif ($Playing) { 'page-transitions-playing' } else { $Scenario }
$package = 'com.doujin.audio.perf'
$activity = "$package/com.doujin.audio.MainActivity"
$manifest = if ($ProductionStartup -or $GeneratedCovers) { '' } else { "/data/user/0/$package/cache/profile-covers/manifest.json" }
$generatedCoverDefine = $GeneratedCovers.IsPresent.ToString().ToLowerInvariant()
$traceReadyFile = "/data/user/0/$package/cache/navigation-profile-trace-ready"
$traceDirectory = Join-Path $OutputDirectory "$Label-timelines-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $traceDirectory | Out-Null
$originalDriverTimeout = $env:PERF_DRIVER_TIMEOUT_SECONDS
$localPort = $null
$restoreJob = $null
$traceJob = $null
$idleJob = $null
$serviceRoot = $null
$driveExit = 1
if (!$Device) {
    $devices = @(& adb devices | Select-String '^([^\s]+)\s+device$' | ForEach-Object { $_.Matches[0].Groups[1].Value })
    if ($devices.Count -ne 1) { throw 'Specify -Device when there is not exactly one online ADB device.' }
    $Device = $devices[0]
}
Push-Location $projectRoot
try {
    if (!$ApkPath) {
        & flutter build apk --profile --no-pub --target=integration_test/ui_performance_test.dart --target-platform=android-arm64 "--dart-define=PERF_SCENARIO=$scenario" "--dart-define=PERF_TRANSITION_CONDITION=$Condition" "--dart-define=PERF_IDLE_SECONDS=$IdleSeconds" "--dart-define=PERF_OPENINGS=$Openings" "--dart-define=PERF_LIBRARY_ITEMS=$LibraryItems" "--dart-define=PERF_ASMR_ITEMS=$AsmrItems" "--dart-define=PERF_ASMR_TRACKS=$AsmrTracks" "--dart-define=PERF_GENERATED_COVERS=$generatedCoverDefine" "--dart-define=PERF_COVER_MANIFEST=$manifest" "--dart-define=PERF_TRACE_READY_FILE=$traceReadyFile" *> "$OutputDirectory/$Label-build.txt"
        if ($LASTEXITCODE -ne 0) { throw 'Profile build failed.' }
        $ApkPath = Join-Path $projectRoot 'build/app/outputs/flutter-apk/app-profile.apk'
        @{ scenario = $scenario; condition = $Condition; idleSeconds = $IdleSeconds; openings = $Openings; libraryItems = $LibraryItems; asmrItems = $AsmrItems; asmrTracks = $AsmrTracks; generatedCovers = $GeneratedCovers.IsPresent; coverManifest = $manifest; traceReadyFile = $traceReadyFile; sha256 = (Get-FileHash -LiteralPath $ApkPath -Algorithm SHA256).Hash } | ConvertTo-Json | Set-Content "$ApkPath.profile.json"
    } else {
        $ApkPath = [IO.Path]::GetFullPath($ApkPath)
        $metadata = Get-Content -LiteralPath "$ApkPath.profile.json" -Raw | ConvertFrom-Json
        if ($metadata.scenario -ne $scenario -or $metadata.condition -ne $Condition -or $metadata.idleSeconds -ne $IdleSeconds -or $metadata.openings -ne $Openings -or $metadata.coverManifest -ne $manifest -or $metadata.traceReadyFile -ne $traceReadyFile -or $metadata.sha256 -ne (Get-FileHash -LiteralPath $ApkPath -Algorithm SHA256).Hash) {
            throw 'APK metadata/hash does not match the requested Profile configuration.'
        }
        if ($metadata.libraryItems -ne $LibraryItems -or $metadata.asmrItems -ne $AsmrItems -or $metadata.asmrTracks -ne $AsmrTracks) {
            throw 'APK datasets do not match the requested Profile configuration.'
        }
        if ([bool]$metadata.generatedCovers -ne $GeneratedCovers.IsPresent) { throw 'APK generated-cover configuration does not match.' }
    }
    & adb -s $Device shell am force-stop $package | Out-Null
    # Profile is a separate debuggable package; preserve its fixture on baseline downgrade.
    & adb -s $Device install -r -d $ApkPath
    if ($LASTEXITCODE -ne 0) { throw 'Profile APK installation failed.' }
    if (!$ProductionStartup -and !$GeneratedCovers) {
        & adb -s $Device shell run-as $package test -f cache/profile-covers/manifest.json
        if ($LASTEXITCODE -ne 0) { throw 'Install the cover fixture before profiling.' }
    }
    & adb -s $Device shell run-as $package rm -f cache/navigation-profile-trace-ready
    if ([IO.Path]::GetFullPath($ApkPath) -ne [IO.Path]::GetFullPath("$OutputDirectory/$Label.apk")) {
        Copy-Item -LiteralPath $ApkPath -Destination "$OutputDirectory/$Label.apk"
        Copy-Item -LiteralPath "$ApkPath.profile.json" -Destination "$OutputDirectory/$Label.apk.profile.json"
    }
    $launchRequestedAt = [DateTime]::UtcNow.ToString('o')
    & adb -s $Device shell am start -n $activity | Out-Null
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    do {
        Start-Sleep -Seconds 1
        $profilePid = (@(& adb -s $Device shell pidof -s $package) -join '').Trim()
        if ($profilePid) {
            $service = (& adb -s $Device logcat -d --pid=$profilePid -s flutter | Select-String 'The Dart VM service is listening on').Line
        }
    } until ($service -match '(http://127\.0\.0\.1:)(\d+)(/\S+)' -or [DateTime]::UtcNow -gt $deadline)
    if ($service -notmatch '(http://127\.0\.0\.1:)(\d+)(/\S+)') { throw 'Profile VM service did not start.' }
    $remotePort = $Matches[2]
    $authPath = $Matches[3]
    $localPort = (& adb -s $Device forward tcp:0 "tcp:$remotePort").Trim()
    $serviceRoot = "http://127.0.0.1:$localPort$authPath"
    # Raster/GPU engine events are in Embedder; GPU is not a Dart VM stream.
    $streams = [Uri]::EscapeDataString('[Dart,GC,Embedder]')
    $traceResult = Invoke-RestMethod -Uri "${serviceRoot}setVMTimelineFlags?recordedStreams=$streams"
    if ($traceResult.error) { throw 'VM refused timeline tracing.' }
    Invoke-RestMethod -Uri "${serviceRoot}getVMTimelineFlags" | ConvertTo-Json -Depth 10 | Set-Content "$OutputDirectory/$Label-timeline-flags.json"
    $traceJob = Start-Job -ArgumentList $Device, $profilePid, $serviceRoot, $traceDirectory -ScriptBlock {
        param($Device, $profilePid, $serviceRoot, $traceDirectory)
        $ErrorActionPreference = 'Stop'
        $logcat = [Diagnostics.Process]::new()
        $logcat.StartInfo.FileName = (Get-Command adb).Source
        $logcat.StartInfo.Arguments = "-s $Device logcat -T 1 --pid=$profilePid -s flutter"
        $logcat.StartInfo.UseShellExecute = $false
        $logcat.StartInfo.CreateNoWindow = $true
        $logcat.StartInfo.RedirectStandardOutput = $true
        [void]$logcat.Start()
        @{pid=$logcat.Id; startedAt=$logcat.StartTime.ToUniversalTime().ToString('o')} | ConvertTo-Json | Set-Content "$traceDirectory/logcat-process.txt"
        try {
            while ($null -ne ($line = $logcat.StandardOutput.ReadLine())) {
                if ($line -match 'PAGE_TRANSITION_TIMELINE_READY (\{.*\})') {
                    $window = $Matches[1] | ConvertFrom-Json
                    # Downloads happen during the existing two-second timing delivery wait.
                    Start-Sleep -Milliseconds 200
                    $extent = $window.endUs - $window.startUs + 200000
                    $trace = Invoke-WebRequest -Uri "${serviceRoot}getVMTimeline?timeOriginMicros=$($window.startUs)&timeExtentMicros=$extent"
                    $timeline = $trace.Content | ConvertFrom-Json
                    if ($timeline.error) { throw 'VM refused the action timeline window.' }
                    $timeline.result | ConvertTo-Json -Depth 100 -Compress | Set-Content "$traceDirectory/$($window.opening)-$($window.transition).json"
                }
            }
        } finally {
            if (!$logcat.HasExited) { $logcat.Kill() }
            $logcat.Dispose()
        }
    }
    Start-Sleep -Seconds 2
    & adb -s $Device shell run-as $package touch cache/navigation-profile-trace-ready
    & adb -s $Device shell dumpsys display | Out-File "$OutputDirectory/$Label-display-start.txt"
    @{ pid = $profilePid; condition = $Condition; idleSeconds = $IdleSeconds; openings = $Openings; scenario = $scenario; launchRequestedAt = $launchRequestedAt; captureReadyAt=[DateTime]::UtcNow.ToString('o'); timelineDirectory=$traceDirectory } | ConvertTo-Json | Set-Content "$OutputDirectory/$Label-state.json"
    if ($Condition -eq 'os-resume') {
        $restoreJob = Start-Job -ArgumentList $Device, $profilePid, $IdleSeconds, $Openings, $activity, $OutputDirectory, $Label -ScriptBlock {
            param($Device, $profilePid, $IdleSeconds, $Openings, $activity, $OutputDirectory, $Label)
            $restored = 0
            $seenReady = [Collections.Generic.HashSet[string]]::new()
            $deadline = [DateTime]::UtcNow.AddSeconds(($IdleSeconds + 180) * $Openings)
            while ($restored -lt $Openings -and [DateTime]::UtcNow -lt $deadline) {
                & adb -s $Device logcat -d --pid=$profilePid -s flutter | Select-String 'PAGE_TRANSITION_OS_BACKGROUND_READY' | ForEach-Object { [void]$seenReady.Add($_.Line) }
                $ready = $seenReady.Count
                if ($ready -gt $restored) {
                    & adb -s $Device shell input keyevent KEYCODE_HOME
                    # HOME returns before paused is delivered. Keep a five-second margin.
                    $resumeAt = [DateTime]::UtcNow.AddSeconds($IdleSeconds + 5)
                    while ([DateTime]::UtcNow -lt $resumeAt) { Start-Sleep -Seconds 1 }
                    $activation = & adb -s $Device shell am start -n $activity 2>&1
                    if ($LASTEXITCODE -ne 0) { throw "Activity resume failed: $activation" }
                    $activation | ForEach-Object { [string]$_ }
                    $restored++
                    & adb -s $Device shell dumpsys display | Out-File "$OutputDirectory/$Label-display-resume-$restored.txt"
                }
                Start-Sleep -Seconds 1
            }
            if ($restored -ne $Openings) { throw "Only $restored OS cycles completed." }
        }
    }
    if ($Condition -eq 'idle') {
        $idleJob = Start-Job -ArgumentList $Device, $profilePid, $package, $IdleSeconds, $Openings, $OutputDirectory, $Label -ScriptBlock {
            param($Device, $profilePid, $package, $IdleSeconds, $Openings, $OutputDirectory, $Label)
            $ErrorActionPreference = 'Stop'
            $completed = 0
            $seenStarted = [Collections.Generic.HashSet[string]]::new()
            $seenCompleted = [Collections.Generic.HashSet[string]]::new()
            $deadline = [DateTime]::UtcNow.AddSeconds(($IdleSeconds + 180) * $Openings)
            while ($completed -lt $Openings -and [DateTime]::UtcNow -lt $deadline) {
                $markers = & adb -s $Device logcat -d --pid=$profilePid -s flutter
                $markers | Select-String 'PAGE_TRANSITION_IDLE_READY' | ForEach-Object { [void]$seenStarted.Add($_.Line) }
                $markers | Select-String 'PAGE_TRANSITION_IDLE_COMPLETE' | ForEach-Object { [void]$seenCompleted.Add($_.Line) }
                $started = $seenStarted.Count
                $completed = $seenCompleted.Count
                if ($started -gt $completed) {
                    $foreground = & adb -s $Device shell dumpsys activity activities
                    $top = ($foreground | Select-String 'topResumedActivity=' | Select-Object -First 1).Line
                    $currentPid = (@(& adb -s $Device shell pidof -s $package) -join '').Trim()
                    @{checkedAt=[DateTime]::UtcNow.ToString('o'); pid=$currentPid; topResumed=$top} | ConvertTo-Json -Compress | Add-Content "$OutputDirectory/$Label-foreground-checks.jsonl"
                    if ($currentPid -ne $profilePid -or $top -notmatch [Regex]::Escape("$package/")) {
                        @{reason='Foreground idle interrupted'; checkedAt=[DateTime]::UtcNow.ToString('o'); expectedPid=$profilePid; actualPid=$currentPid; topResumed=$top} | ConvertTo-Json | Set-Content "$OutputDirectory/$Label-condition-invalid.json"
                        $foreground | Set-Content "$OutputDirectory/$Label-invalid-activity.txt"
                        # A paused/frozen engine may never finish tester.pump; end only this test package.
                        & adb -s $Device shell am force-stop $package
                        throw 'Foreground idle lost its resumed Activity or original process.'
                    }
                }
                Start-Sleep -Seconds 5
            }
            if ($completed -ne $Openings) { throw "Only $completed foreground idle cycles completed." }
        }
    }
    $env:PERF_DRIVER_TIMEOUT_SECONDS = [string](($IdleSeconds + 180) * $Openings + 600)
    $suffix = if ($ProductionStartup) { 'startup' } elseif ($Playing) { 'playing' } else { 'idle' }
    $responsePath = if ($scenario.StartsWith('page-transitions')) { "build/page_transitions_android_$suffix.json" } else { 'build/integration_response_data.json' }
    if (Test-Path -LiteralPath $responsePath) {
        Move-Item -LiteralPath $responsePath -Destination "$OutputDirectory/$Label-previous-report.json" -Force
    }
    & flutter drive --profile --no-pub "--device-id=$Device" --driver=test_driver/ui_performance_test.dart --target=integration_test/ui_performance_test.dart "--use-existing-app=http://127.0.0.1:$localPort$authPath" *> "$OutputDirectory/$Label-drive.txt"
    $driveExit = $LASTEXITCODE
    if (!(Test-Path -LiteralPath $responsePath)) {
        $interruption = (Select-String -LiteralPath "$OutputDirectory/$Label-drive.txt" -Pattern 'PAGE_TRANSITION_IDLE_INTERRUPTED|Foreground idle was interrupted' | ForEach-Object { $_.Line }) -join "`n"
        if ($interruption) {
            @{reason=$interruption; checkedAt=[DateTime]::UtcNow.ToString('o'); expectedPid=$profilePid} | ConvertTo-Json | Set-Content "$OutputDirectory/$Label-condition-invalid.json"
        }
        throw 'This driver run produced no Profile report.'
    }
    if ($idleJob) {
        Receive-Job $idleJob -Wait -AutoRemoveJob | Out-File "$OutputDirectory/$Label-foreground-job.txt"
    }
    if ($restoreJob) {
        Receive-Job $restoreJob -Wait -AutoRemoveJob | Out-File "$OutputDirectory/$Label-background.txt"
    }
    Copy-Item -LiteralPath $responsePath -Destination "$OutputDirectory/$Label.json"
    $report = (Get-Content -LiteralPath $responsePath -Raw | ConvertFrom-Json).uiPerformance
    if ($report.scenario -ne $scenario -or $report.transitionCondition -ne $Condition -or $report.idleSeconds -ne $IdleSeconds -or $report.openings -ne $Openings) {
        throw 'Reported Profile configuration does not match the requested configuration.'
    }
    $traceDeadline = [DateTime]::UtcNow.AddSeconds(60)
    do {
        $traceCount = @(Get-ChildItem -LiteralPath $traceDirectory -Filter '*.json').Count
        if ($traceCount -eq $report.rounds.Count) { break }
        if ($traceJob.State -eq 'Failed') { break }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $traceDeadline)
    if ($traceCount -ne $report.rounds.Count) { throw "Only $traceCount of $($report.rounds.Count) action timelines captured." }
    & adb -s $Device shell dumpsys display | Out-File "$OutputDirectory/$Label-display-end.txt"
    & adb -s $Device shell dumpsys meminfo $package | Out-File "$OutputDirectory/$Label-memory.txt"
    & adb -s $Device logcat -d --pid=$profilePid -s flutter | Out-File "$OutputDirectory/$Label-logcat.txt"
} finally {
    if ($traceJob) {
        # Stop-Job alone may leave its native child alive after the job host exits.
        $logcatRecord = Join-Path $traceDirectory 'logcat-process.txt'
        if (Test-Path -LiteralPath $logcatRecord) {
            $record = Get-Content -LiteralPath $logcatRecord -Raw | ConvertFrom-Json
            $process = Get-Process -Id $record.pid -ErrorAction SilentlyContinue
            if ($process -and $process.ProcessName -eq 'adb' -and $process.StartTime.ToUniversalTime().ToString('o') -eq $record.startedAt) {
                Stop-Process -Id $record.pid -Force -ErrorAction SilentlyContinue
            }
        }
        Stop-Job $traceJob
        Receive-Job $traceJob -ErrorAction Continue | Out-File "$OutputDirectory/$Label-timeline-job.txt"
        Remove-Job $traceJob
    }
    if ($serviceRoot) {
        try { Invoke-RestMethod -Uri "${serviceRoot}setVMTimelineFlags?recordedStreams=%5B%5D" -TimeoutSec 5 | Out-Null }
        catch { Write-Warning 'The app disconnected before timeline streams could be disabled.' }
    }
    if ($restoreJob -and (Get-Job -Id $restoreJob.Id -ErrorAction SilentlyContinue)) {
        Stop-Job $restoreJob
        Remove-Job $restoreJob
    }
    if ($idleJob -and (Get-Job -Id $idleJob.Id -ErrorAction SilentlyContinue)) {
        Stop-Job $idleJob
        Remove-Job $idleJob
    }
    if ($localPort) { & adb -s $Device forward --remove "tcp:$localPort" | Out-Null }
    $env:PERF_DRIVER_TIMEOUT_SECONDS = $originalDriverTimeout
    Pop-Location
}
exit $driveExit
