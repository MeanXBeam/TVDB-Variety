# Jellyfin Japanese Variety Renamer - TMDB API FIRST, TVDB API FALLBACK
# Preview by default. Add -Apply to rename files.
# Add -TestApi to only test the live TMDB/TVDB API connections and exit.
#
# Matching order:
#   1. Date in filename
#   2. Verified TVer-ID -> broadcaster date fallback (for known undated files)
#   3. TMDB API exact air-date match (PRIMARY)
#   4. TVDB API exact air-date match (FALLBACK)
#   5. REVIEW if neither source gives exactly one episode
#
# TVer IDs are NEVER used as episode numbers. They are preserved as:
#   (TVer-epXXXXXXXX)

param(
    [string]$Root = "(insert your library folder path here)",
    [switch]$Apply,
    [switch]$IncludeMkv,
    [switch]$TestApi
)

$ErrorActionPreference = "Stop"

# -----------------------------------------------------------------------------
# API KEYS - fill these in with your own before running.
# TMDB: https://www.themoviedb.org/settings/api
# TVDB: https://thetvdb.com/dashboard/account/apikey
# -----------------------------------------------------------------------------
$TmdbApiKey = "(insert api key here)"
$TvdbApiKey = "(insert api key here)"

# -----------------------------------------------------------------------------
# Exact folder names from the user's actual library screenshot.
# Hashtable keys are case-insensitive in PowerShell.
# -----------------------------------------------------------------------------
$ShowMap = @{
    "Achikochi Audrey"       = "achikochiodori"
    "Ametalk!"               = "ame-talk"
    "Ametalk"                = "ame-talk"
    "Ariyoshiieeeee!"        = "ying-jing-you-ji-theye-hui"
    "Ariyoshiieeeee"         = "ying-jing-you-ji-theye-hui"
    "Atarashii Kagi"         = "414448-"
    "Can I Follow You Home"  = "ie-tsuitette-iidesuka"
    "Chidori no Oni Renchan" = "chidori-no-oni-renchan"
    "Cream Nantara"           = "411507-"
    "Geinoujin ga honki"      = "dokkiri-gp"
    "god tongue"              = "god-tan"
    "Hanadai Chidori"         = ""
    "ItteQ"                   = "273667-show"
    "knight scoop"            = "tantei-knight-scoop"
    "london Hearts"           = "londonhearts"
    "Mitorizu"                = "mitorizujan"
    "Sakurai Ariyoshi"       = "sakurai-ariyoshi-the-night-party"
    "Shabekuri 007"           = "shabekuri-007"
    "Wednesday Downtown"      = "wednesdays-downtown"
}

# TMDB IDs supplied by the user. TMDB is PRIMARY.
$TmdbMap = @{
    "Achikochi Audrey"       = 123945
    "Ametalk!"               = 111558
    "Ametalk"                = 111558
    "Ariyoshiieeeee!"        = 111392
    "Ariyoshiieeeee"         = 111392
    "Atarashii Kagi"         = 124084
    "Can I Follow You Home"  = 112110
    "Chidori no Oni Renchan" = 203768
    "Cream Nantara"           = 196794
    "Geinoujin ga honki"      = 106811
    "god tongue"              = 113763
    "Hanadai Chidori"         = 123869
    "ItteQ"                   = 81177
    "knight scoop"            = 111617
    "london Hearts"           = 45804
    "Mitorizu"                = 247182
    "Sakurai Ariyoshi"       = 111556
    "Shabekuri 007"           = 107550
    "Wednesday Downtown"      = 108112
}

# Known TVDB series IDs where the user supplied/confirmed them or the series page
# gives a stable ID. Slugs remain as fallback for the others.
$TvdbIdMap = @{
    "Achikochi Audrey"       = 473753
    "Atarashii Kagi"         = 414448
    "Cream Nantara"           = 411507
    "ItteQ"                   = 273667
    "Wednesday Downtown"      = 338042
    "knight scoop"            = 320092
    "london Hearts"           = 250866
}

# Exact undated TVer IDs -> verified broadcaster airdate.
# Entries containing ?? are intentionally NOT used until verified.
$OfficialDateByTverId = @{
    "epbrut3l3d" = "2026-??-??"
    "epmn0ql1oy" = "2025-10-06"
    "epv0ma01fo" = "2026-08-17"
    "epphnkjvyz" = "2025-11-17"
    "epj8onivmp" = "2026-08-24"
    "epc2qz9o33" = "2026-08-18"
    "epl0g37jza" = "2026-08-25"
    "epwpuru9or" = "2026-08-23"
    "epnt98ax6c" = "2026-??-??"
    "ep2zk8jusv" = "2026-??-??"
    "eptli2mhwd" = "2026-08-13"
    "epfgz3lfsa" = "2026-08-06"
    "epk4d232n4" = "2026-07-30"
    "ep6vg8t6yp" = "2026-07-16"
    "ep2bbjrxky" = "2026-07-09"
    "epr3ik8go4" = "2026-07-23"
    "epc67m3zqk" = "2026-07-02"
    "epc7axx133" = "2026-06-25"
    "epj4osmtn1" = "2026-07-02"
    "ep2ovpcxvf" = "2026-06-25"
}

$extensions = @(".mp4")
if ($IncludeMkv) { $extensions += ".mkv" }

# Fresh cache namespace so results from the broken earlier versions cannot poison this run.
$cacheDir = Join-Path $env:TEMP "jellyfin-japanese-variety-api-v3"
New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null

function Invoke-JsonRequest {
    param(
        [Parameter(Mandatory=$true)][string]$Url,
        [hashtable]$Headers = $null,
        [ValidateSet("GET","POST")][string]$Method = "GET",
        [string]$Body = $null,
        [switch]$NoCache
    )

    $cache = $null
    if (-not $NoCache -and $Method -eq "GET") {
        $hashBytes = [Text.Encoding]::UTF8.GetBytes($Url)
        $sha = [Security.Cryptography.SHA256]::Create()
        $hash = [BitConverter]::ToString($sha.ComputeHash($hashBytes)).Replace("-", "").ToLowerInvariant()
        $cache = Join-Path $cacheDir "$hash.json"
        if (Test-Path -LiteralPath $cache) {
            try { return Get-Content -Raw -Encoding UTF8 $cache | ConvertFrom-Json } catch {}
        }
    }

    try {
        if ($Method -eq "POST") {
            if ($Headers) {
                $result = Invoke-RestMethod -Uri $Url -Method Post -Headers $Headers -ContentType "application/json" -Body $Body
            } else {
                $result = Invoke-RestMethod -Uri $Url -Method Post -ContentType "application/json" -Body $Body
            }
        } else {
            if ($Headers) {
                $result = Invoke-RestMethod -Uri $Url -Method Get -Headers $Headers
            } else {
                $result = Invoke-RestMethod -Uri $Url -Method Get
            }
        }
        if ($cache) {
            ($result | ConvertTo-Json -Depth 50) | Set-Content -Encoding UTF8 $cache
        }
        return $result
    } catch {
        $msg = $_.Exception.Message
        throw "API request failed: $Url`n$msg"
    }
}

function Get-TmdbSeries([int]$TmdbId) {
    $url = "https://api.themoviedb.org/3/tv/${TmdbId}?api_key=$([uri]::EscapeDataString($TmdbApiKey))&language=ja-JP"
    Invoke-JsonRequest -Url $url
}

function Get-TmdbEpisodes([int]$TmdbId) {
    $series = Get-TmdbSeries $TmdbId
    if (-not $series) { throw "TMDB returned no series data for ID $TmdbId." }
    if (-not $series.seasons) { throw "TMDB returned no season list for series ID $TmdbId." }

    $rows = New-Object System.Collections.Generic.List[object]
    $seasonNumbers = @($series.seasons | ForEach-Object { $_.season_number } | Where-Object { $null -ne $_ } | Sort-Object -Unique)

    foreach ($seasonNumber in $seasonNumbers) {
        $url = "https://api.themoviedb.org/3/tv/$TmdbId/season/${seasonNumber}?api_key=$([uri]::EscapeDataString($TmdbApiKey))&language=ja-JP"
        $data = Invoke-JsonRequest -Url $url
        if (-not $data) { continue }

        foreach ($ep in @($data.episodes)) {
            if (-not $ep.air_date) { continue }
            try { $date = [datetime]::ParseExact([string]$ep.air_date, "yyyy-MM-dd", $null) } catch { continue }
            $rows.Add([pscustomobject]@{
                Source  = "TMDB"
                Season  = [int]$seasonNumber
                Episode = [int]$ep.episode_number
                Date    = $date
                Key     = [string]$ep.air_date
                Name    = [string]$ep.name
            })
        }
    }

    return $rows
}

function Get-TvdbToken {
    $body = @{ apikey = $TvdbApiKey } | ConvertTo-Json
    $r = Invoke-JsonRequest -Url "https://api4.thetvdb.com/v4/login" -Method POST -Body $body -NoCache
    if (-not $r.data.token) { throw "TVDB login returned no token." }
    return [string]$r.data.token
}

$TvdbToken = $null
$TvdbHeaders = $null

function Initialize-Tvdb {
    if ($script:TvdbToken) { return }
    $script:TvdbToken = Get-TvdbToken
    $script:TvdbHeaders = @{ Authorization = "Bearer $script:TvdbToken" }
}

function Get-TvdbSeries([string]$showFolder) {
    Initialize-Tvdb

    if ($TvdbIdMap.ContainsKey($showFolder)) {
        $id = [int]$TvdbIdMap[$showFolder]
        $url = "https://api4.thetvdb.com/v4/series/$id"
        return (Invoke-JsonRequest -Url $url -Headers $TvdbHeaders)
    }

    $slug = $ShowMap[$showFolder]
    if (-not $slug) { return $null }
    $url = "https://api4.thetvdb.com/v4/series/slug/$slug"
    return (Invoke-JsonRequest -Url $url -Headers $TvdbHeaders)
}

function Get-TvdbEpisodesForDate([int]$SeriesId, [string]$DateKey) {
    Initialize-Tvdb
    $url = "https://api4.thetvdb.com/v4/series/$SeriesId/episodes/official?airDate=$DateKey&page=0"
    $data = Invoke-JsonRequest -Url $url -Headers $TvdbHeaders
    if (-not $data) { return @() }

    $episodes = @()
    if ($data.data -and $data.data.episodes) { $episodes = @($data.data.episodes) }
    elseif ($data.data -and $data.data.series -and $data.data.series.episodes) { $episodes = @($data.data.series.episodes) }

    $rows = @()
    foreach ($ep in $episodes) {
        $aired = $ep.aired
        if (-not $aired) { $aired = $ep.airDate }
        if (-not $aired) { continue }

        $season = $ep.seasonNumber
        if ($null -eq $season) { $season = $ep.airedSeason }
        $episode = $ep.number
        if ($null -eq $episode) { $episode = $ep.airedEpisodeNumber }
        if ($null -eq $season -or $null -eq $episode) { continue }

        $rows += [pscustomobject]@{
            Source  = "TVDB"
            Season  = [int]$season
            Episode = [int]$episode
            Date    = [string]$aired
            Key     = $DateKey
            Name    = [string]$ep.name
        }
    }
    return @($rows)
}

function Find-ShowFolder([string]$FilePath) {
    $probe = Split-Path $FilePath -Parent
    $rootPath = [IO.Path]::GetPathRoot($probe)
    while ($probe -and $probe -ne $rootPath) {
        $leaf = Split-Path $probe -Leaf
        if ($ShowMap.ContainsKey($leaf)) { return $leaf }
        $probe = Split-Path $probe -Parent
    }
    return $null
}

function Parse-File([string]$Path) {
    $name = [IO.Path]::GetFileNameWithoutExtension($Path)
    $showFolder = Find-ShowFolder $Path

    $date = $null
    $dm = [regex]::Match($name, '^(?<d>\d{6})\s+')
    if ($dm.Success) { try { $date = [datetime]::ParseExact($dm.Groups["d"].Value, "yyMMdd", $null) } catch {} }
    if (-not $date) {
        $dm = [regex]::Match($name, '(?<d>20\d{2}-\d{2}-\d{2})')
        if ($dm.Success) { try { $date = [datetime]::ParseExact($dm.Groups["d"].Value, "yyyy-MM-dd", $null) } catch {} }
    }

    $tm = [regex]::Match($name, '\[(?:TVer-)?(?<id>ep[a-z0-9]+)\]', 'IgnoreCase')
    if (-not $tm.Success) { $tm = [regex]::Match($name, '\(TVer-(?<id>ep[a-z0-9]+)\)', 'IgnoreCase') }
    $tverId = if ($tm.Success) { $tm.Groups["id"].Value.ToLowerInvariant() } else { $null }

    return [pscustomobject]@{
        Path=$Path; Name=$name; Extension=[IO.Path]::GetExtension($Path)
        ShowFolder=$showFolder; Date=$date; TverId=$tverId
    }
}

function Clean-Name([string]$Name) {
    $x = [regex]::Replace($Name, '\s*\[(TVer-)?ep[a-z0-9]+\]', '', 'IgnoreCase')
    $x = [regex]::Replace($x, '\s*\(TVer-ep[a-z0-9]+\)', '', 'IgnoreCase')
    $x = [regex]::Replace($x, '^\d{6}\s+', '')
    $x = [regex]::Replace($x, '^20\d{2}-\d{2}-\d{2}\s*[-–—]\s*', '')
    $x = [regex]::Replace($x, '\s*\[(1080p|REQUEST)\]', '', 'IgnoreCase')
    return ($x -replace '\s+', ' ').Trim()
}

function Test-TmdbApi {
    Write-Host "=== TMDB API TEST ===" -ForegroundColor Cyan
    Write-Host "Series: Achikochi Audrey (TMDB 123945)"
    Write-Host "Date:   2026-08-25"
    $episodes = @(Get-TmdbEpisodes 123945)
    $matches = @($episodes | Where-Object { $_.Key -eq "2026-08-25" })
    Write-Host "TMDB returned $($episodes.Count) dated episodes across $(@($episodes | Select-Object -ExpandProperty Season -Unique).Count) seasons." -ForegroundColor DarkCyan
    if ($matches.Count -eq 1) {
        $m = $matches[0]
        Write-Host "SUCCESS: TMDB match = S$($m.Season)E$('{0:D2}' -f $m.Episode) - $($m.Name)" -ForegroundColor Green
    } elseif ($matches.Count -eq 0) {
        Write-Host "NO MATCH: TMDB API works, but it returned no episode with air_date 2026-08-25 for this series." -ForegroundColor Yellow
    } else {
        Write-Host "AMBIGUOUS: TMDB returned $($matches.Count) episodes on 2026-08-25." -ForegroundColor Yellow
        $matches | ForEach-Object { Write-Host "  S$($_.Season)E$($_.Episode) $($_.Name)" }
    }
}

function Test-TvdbApi {
    Write-Host "=== TVDB API TEST ===" -ForegroundColor Cyan
    Initialize-Tvdb
    Write-Host "TVDB login: SUCCESS" -ForegroundColor Green
    $series = Get-TvdbSeries "Achikochi Audrey"
    if ($series -and $series.data) {
        Write-Host "TVDB series lookup: SUCCESS (ID $($series.data.id))" -ForegroundColor Green
    } else {
        Write-Host "TVDB series lookup returned no data." -ForegroundColor Yellow
    }
}

if ($TestApi) {
    Test-TmdbApi
    Write-Host ""
    Test-TvdbApi
    exit 0
}

# -----------------------------------------------------------------------------
# LIVE API smoke test before touching the library.
# This prevents a broken key/network/API response from silently producing a huge REVIEW CSV.
# -----------------------------------------------------------------------------
Test-TmdbApi
Write-Host ""
Test-TvdbApi
Write-Host ""

$files = @(Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() })
$tmdbCache = @{}
$tvdbCache = @{}
$plans = @()
$review = @()

foreach ($f in $files) {
    $p = Parse-File $f.FullName

    if (-not $p.ShowFolder) {
        $review += [pscustomobject]@{File=$f.FullName; ShowFolder=""; Date=""; TVer=$p.TverId; Reason="Unmapped show folder"}
        continue
    }

    if (-not $p.Date -and $p.TverId -and $OfficialDateByTverId.ContainsKey($p.TverId)) {
        $raw = [string]$OfficialDateByTverId[$p.TverId]
        if ($raw -notmatch '\?') {
            $p.Date = [datetime]::ParseExact($raw, "yyyy-MM-dd", $null)
        } else {
            $review += [pscustomobject]@{File=$f.FullName; ShowFolder=$p.ShowFolder; Date=""; TVer=$p.TverId; Reason="Official-source fallback still needs confirmation for TVer ID $($p.TverId)"}
            continue
        }
    }

    if (-not $p.Date) {
        $review += [pscustomobject]@{File=$f.FullName; ShowFolder=$p.ShowFolder; Date=""; TVer=$p.TverId; Reason="No date in filename and no verified official-source fallback"}
        continue
    }

    $key = $p.Date.ToString("yyyy-MM-dd")
    $matched = $null
    $source = $null
    $tmdbCount = 0
    $tvdbCount = 0

    # ========================= TMDB FIRST =========================
    if ($TmdbMap.ContainsKey($p.ShowFolder)) {
        $tmdbId = [int]$TmdbMap[$p.ShowFolder]
        if (-not $tmdbCache.ContainsKey($tmdbId)) {
            try {
                Write-Host "Loading TMDB $tmdbId for '$($p.ShowFolder)'..." -ForegroundColor DarkGray
                $tmdbCache[$tmdbId] = @(Get-TmdbEpisodes $tmdbId)
            } catch {
                $review += [pscustomobject]@{
                    File=$f.FullName; ShowFolder=$p.ShowFolder; Date=$key; TVer=$p.TverId
                    Reason="TMDB API error for series ${tmdbId}: $($_.Exception.Message)"
                }
                continue
            }
        }

        $tmdbSame = @($tmdbCache[$tmdbId] | Where-Object { $_.Key -eq $key })
        $tmdbCount = $tmdbSame.Count

        if ($tmdbCount -eq 1) {
            $matched = $tmdbSame[0]
            $source = "TMDB"
        } elseif ($tmdbCount -gt 1) {
            $review += [pscustomobject]@{File=$f.FullName; ShowFolder=$p.ShowFolder; Date=$key; TVer=$p.TverId; Reason="TMDB has $tmdbCount episodes for $key; not guessing"}
            continue
        }
    }

    # ========================= TVDB FALLBACK =========================
    if (-not $matched) {
        try {
            $tvdbKey = $p.ShowFolder
            if (-not $tvdbCache.ContainsKey($tvdbKey)) {
                $tvdbCache[$tvdbKey] = Get-TvdbSeries $p.ShowFolder
            }
            $series = $tvdbCache[$tvdbKey]

            if ($series -and $series.data -and $series.data.id) {
                $tvdbSame = @(Get-TvdbEpisodesForDate ([int]$series.data.id) $key)
                $tvdbCount = $tvdbSame.Count
                if ($tvdbCount -eq 1) {
                    $matched = $tvdbSame[0]
                    $source = "TVDB"
                } elseif ($tvdbCount -gt 1) {
                    $review += [pscustomobject]@{File=$f.FullName; ShowFolder=$p.ShowFolder; Date=$key; TVer=$p.TverId; Reason="TVDB has $tvdbCount episodes for $key; not guessing"}
                    continue
                }
            }
        } catch {
            $review += [pscustomobject]@{
                File=$f.FullName; ShowFolder=$p.ShowFolder; Date=$key; TVer=$p.TverId
                Reason="TVDB API error: $($_.Exception.Message)"
            }
            continue
        }
    }

    if (-not $matched) {
        $review += [pscustomobject]@{
            File=$f.FullName; ShowFolder=$p.ShowFolder; Date=$key; TVer=$p.TverId
            Reason="No unique TMDB or TVDB episode for $key (TMDB matches=$tmdbCount, TVDB matches=$tvdbCount)"
        }
        continue
    }

    $prefix = $p.Date.ToString("yyMMdd")
    $token = "S{0}E{1:D2}" -f $matched.Season, $matched.Episode
    $clean = Clean-Name $p.Name
    $newCore = "$prefix $token $clean"
    if ($p.TverId) { $newCore += " (TVer-$($p.TverId))" }
    $newPath = Join-Path $f.DirectoryName ($newCore + $p.Extension)

    if ($newPath -ne $f.FullName) {
        $plans += [pscustomobject]@{
            Old=$f.FullName; New=$newPath; AirDate=$key
            EpisodeCode=$token; Source=$source
            TVer=if($p.TverId){"TVer-$($p.TverId)"}else{""}
        }
    }
}

$preview = Join-Path $Root "TVDB_RENAME_PREVIEW.csv"
$reviewPath = Join-Path $Root "TVDB_RENAME_REVIEW.csv"
$plans | Export-Csv -NoTypeInformation -Encoding UTF8 $preview
$review | Export-Csv -NoTypeInformation -Encoding UTF8 $reviewPath

Write-Host ""
Write-Host "Checked $($files.Count) files recursively." -ForegroundColor Cyan
Write-Host "Safe rename candidates: $($plans.Count)" -ForegroundColor Green
Write-Host "Needs review: $($review.Count)" -ForegroundColor Yellow
Write-Host ""
Write-Host "Preview CSV: $preview"
Write-Host "Review CSV:  $reviewPath"
Write-Host ""

foreach ($x in $plans) {
    Write-Host $x.Old
    Write-Host "  -> $($x.New) [$($x.Source)]" -ForegroundColor DarkCyan
}

if ($Apply) {
    Write-Host ""
    Write-Host "APPLYING..." -ForegroundColor Yellow
    foreach ($x in $plans) {
        if (Test-Path -LiteralPath $x.New) {
            Write-Warning "Skipped because destination exists: $($x.New)"
            continue
        }
        Rename-Item -LiteralPath $x.Old -NewName ([IO.Path]::GetFileName($x.New))
    }
    Write-Host "Done." -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "PREVIEW ONLY - no files changed." -ForegroundColor Green
    Write-Host "After checking the CSV, run with -Apply."
}
