while ($true) {
    try {
        $out = gh run view 28773778566 --json status,conclusion | ConvertFrom-Json
        if ($out.status -eq "completed") {
            Write-Host "Run completed with conclusion: $($out.conclusion)"
            break
        } else {
            Write-Host "Status: $($out.status) (sleeping 30s)"
            Start-Sleep -Seconds 30
        }
    } catch {
        Write-Host "Error polling. Retrying..."
        Start-Sleep -Seconds 10
    }
}
