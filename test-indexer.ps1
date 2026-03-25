Set-StrictMode -Version Latest
$obj = [PSCustomObject]@{ A = 1 }
try {
    $p = $obj.PSObject.Properties['B']
    if ($null -eq $p) { Write-Host "Result is null" }
} catch {
    Write-Host "Caught: $_"
}
