& {
    $ErrorActionPreference = 'Stop'
    $OutputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
    if (!(Get-Command ffmpeg -ErrorAction SilentlyContinue) -or !(Get-Command ffprobe -ErrorAction SilentlyContinue)) {
        throw 'FFmpeg not found. Install FFmpeg and reopen PowerShell.'
    }
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = 'Select an MP4 music compilation'
    $dialog.Filter = 'MP4 (*.mp4)|*.mp4'
    if ($dialog.ShowDialog() -ne 'OK') { return }
    $video = $dialog.FileName
    $raw = & ffprobe -v error -show_format -of json "$video"
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read the MP4 file.' }
    $info = ($raw | Out-String) | ConvertFrom-Json
    $description = [string]$info.format.tags.description
    if ([string]::IsNullOrWhiteSpace($description)) { $description = [string]$info.format.tags.comment }
    $pattern = '(?m)^[ \t]*\[?((?:\d{1,2}:)?\d{1,2}:\d{2})\]?[ \t]+(?:\d+[.)][ \t]*)?([^\r\n]+)'
    $entries = [regex]::Matches($description, $pattern)
    $wholeMix = $entries.Count -lt 2
    $trackNumber = 0
    $tracks = @(
        if ($wholeMix) {
            Write-Host 'No usable tracklist found. Creating ONE complete MP3 with a cover; no automatic splitting.'
            [pscustomobject]@{ Start = 0; Number = 1; Title = [System.IO.Path]::GetFileNameWithoutExtension($video) }
        } else { foreach ($entry in $entries) {
            $seconds = 0
            foreach ($part in $entry.Groups[1].Value.Split(':')) { $seconds = $seconds * 60 + [int]$part }
            $trackNumber++
            [pscustomobject]@{ Start = $seconds; Number = $trackNumber; Title = $entry.Groups[2].Value.Trim() }
        } }
    )
    $totalSeconds = [double]::Parse([string]$info.format.duration, [System.Globalization.CultureInfo]::InvariantCulture)
    for ($i = 0; $i -lt $tracks.Count; $i++) {
        if ($tracks[$i].Start -ge $totalSeconds) { throw 'A timestamp exceeds the video duration.' }
        if ($i -gt 0 -and $tracks[$i].Start -le $tracks[$i - 1].Start) { throw 'Track timestamps are not in increasing order.' }
    }
    if ($totalSeconds -le 90) { throw 'Video is too short for a cover at 01:30.' }
    $folder = Join-Path (Split-Path $video) ('Tracks_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
    New-Item -ItemType Directory -Path $folder | Out-Null
    $cover = Join-Path $folder 'cover.jpg'
    Write-Host 'Extracting the cover at 01:30...'
    & ffmpeg -hide_banner -loglevel error -nostdin -n -ss 90 -i "$video" -map 0:v:0 -frames:v 1 -q:v 2 "$cover"
    if ($LASTEXITCODE -ne 0 -or !(Test-Path $cover)) { throw 'Cannot extract the cover image.' }
    for ($i = 0; $i -lt $tracks.Count; $i++) {
        $track = $tracks[$i]
        $name = '{0:D2} - {1}' -f $track.Number, $track.Title
        $name = ($name -replace '[<>:"/\\|?*\x00-\x1F]', '_').TrimEnd(' ', '.')
        if ($name.Length -gt 150) { $name = $name.Substring(0, 150).TrimEnd(' ', '.') }
        $output = Join-Path $folder ($name + '.mp3')
        $ffargs = @('-hide_banner', '-loglevel', 'error', '-nostdin', '-n', '-ss', [string]$track.Start, '-i', $video, '-i', $cover)
        if ($i + 1 -lt $tracks.Count) { $ffargs += @('-t', [string]($tracks[$i + 1].Start - $track.Start)) }
        $ffargs += @(
            '-map', '0:a:0', '-map', '1:v:0', '-map_metadata', '-1',
            '-c:a', 'libmp3lame', '-q:a', '2', '-c:v', 'copy',
            '-disposition:v:0', 'attached_pic', '-id3v2_version', '3',
            '-metadata', "title=$($track.Title)",
            '-metadata', "track=$($track.Number)/$($tracks.Count)",
            '-metadata:s:v', 'title=Album cover',
            '-metadata:s:v', 'comment=Cover (front)', $output
        )
        Write-Host "Creating: $name"
        & ffmpeg @ffargs
        if ($LASTEXITCODE -ne 0) { throw "Failed to create: $name" }
    }
    Write-Host "Done! MP3 files created: $($tracks.Count)"
    Invoke-Item $folder
}
