param(
    [int]$FirstId = 0,
    [int]$LastId = 0x7ff,
    [int]$Sweeps = 1,
    [int]$Dlc = 8,
    [string]$Payload = '00FF55AA12345678',
    [int]$BitTimeNs = 1000,
    [int]$ExtraIdleBits = 0,
    [int]$DumpFrames = 4,
    [switch]$RecessiveAck
)
$ErrorActionPreference = 'Stop'
if ($Payload -notmatch '^[0-9a-fA-F]{16}$') {
    throw 'Payload must contain exactly 16 hexadecimal digits (eight bytes).'
}
$localBin = Join-Path $PSScriptRoot '../../tmp/tools/icarus/mingw64/bin'
if (Test-Path (Join-Path $localBin 'iverilog.exe')) {
    $compiler = (Resolve-Path (Join-Path $localBin 'iverilog.exe')).Path
    $runtime = (Resolve-Path (Join-Path $localBin 'vvp.exe')).Path
} else {
    $compiler = (Get-Command iverilog -ErrorAction Stop).Source
    $runtime = (Get-Command vvp -ErrorAction Stop).Source
}
$originalPath = $env:PATH
$env:PATH = (Split-Path $compiler) + ';' + $env:PATH
$outDir = Join-Path $PSScriptRoot 'out'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
Push-Location $outDir
try {
    $compileArgs = @(
        '-g2012', '-Wall', '-s', 'tb_can_stimulus',
        '-o', 'can_stimulus.vvp',
        "-Ptb_can_stimulus.FIRST_ID=$FirstId",
        "-Ptb_can_stimulus.LAST_ID=$LastId",
        "-Ptb_can_stimulus.SWEEPS=$Sweeps",
        "-Ptb_can_stimulus.DLC=$Dlc",
        "-Ptb_can_stimulus.PAYLOAD=64'h$Payload",
        "-Ptb_can_stimulus.BIT_TIME_NS=$BitTimeNs",
        "-Ptb_can_stimulus.EXTRA_IDLE_BITS=$ExtraIdleBits",
        "-Ptb_can_stimulus.DUMP_FRAMES=$DumpFrames",
        ('-Ptb_can_stimulus.ACK_DOMINANT=' + [int](-not $RecessiveAck)),
        (Join-Path $PSScriptRoot 'tb_can_stimulus.sv')
    )
    & $compiler @compileArgs
    if ($LASTEXITCODE -ne 0) { throw 'CAN testbench compilation failed.' }
    & $runtime can_stimulus.vvp '+trace=frames.tsv'
    if ($LASTEXITCODE -ne 0) { throw 'CAN stimulus simulation failed.' }
    if ($Sweeps -gt 0) {
        $checkArgs = @(
            (Join-Path $PSScriptRoot 'check_can_trace.py'), 'frames.tsv',
            '--first-id', $FirstId, '--last-id', $LastId, '--sweeps', $Sweeps,
            '--payload', $Payload, '--dlc', $Dlc,
            '--bit-time-ns', $BitTimeNs, '--extra-idle-bits', $ExtraIdleBits
        )
        if ($RecessiveAck) { $checkArgs += '--recessive-ack' }
        & python @checkArgs
        if ($LASTEXITCODE -ne 0) { throw 'Generated CAN frames failed validation.' }
    }
} finally {
    Pop-Location
    $env:PATH = $originalPath
}
