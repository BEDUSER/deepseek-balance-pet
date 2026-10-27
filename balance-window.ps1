<#
  余额小窗 (Balance Window)  for DSH + dsh-whale-widget
  ------------------------------------------------------------------
  零依赖：只用 Windows 自带的 PowerShell 5.1 + WPF。
  数据源：dsh-whale-widget 的本地账本  ~/.dsh/.dshw-usage.json
          （挂件每 60s 刷新一次该文件，本窗每 3s 重读）
        + 官方余额接口 https://api.deepseek.com/user/balance   （key 放 api-key.txt）
        + 第三方中转站余额（new-api / one-api 系额度接口，默认 88api）（key 放 third-key.txt）

  行为：无边框 / 透明背景 / 置顶 / 可拖动 / 右键菜单
  位置与开关保存在  ~/.dsh/.balance-window.json
#>
#Requires -Version 5.1

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
# 联网查余额要用；PowerShell 5.1 默认不加载这个程序集
Add-Type -AssemblyName System.Net.Http

$ErrorActionPreference = 'Stop'

# DSH 的数据目录：进程环境变量 → 用户级注册表 → ~\.dsh
# （小窗可能由资源管理器启动，那时进程里不一定有 DSH_HOME，所以多一层注册表回退）
$DshHome = $env:DSH_HOME
if (-not $DshHome) { try { $DshHome = [Environment]::GetEnvironmentVariable('DSH_HOME', 'User') } catch { } }
if (-not $DshHome) { $DshHome = Join-Path $env:USERPROFILE '.dsh' }
$UsageFile  = Join-Path $DshHome '.dshw-usage.json'
# 状态文件写在脚本自己所在目录，避免往 C: 盘塞文件（目录只读时自动降级为不保存）
$StateFile  = Join-Path $PSScriptRoot '.balance-window.json'
# 开机自启用注册表 Run 项，不产生任何文件
$RunKey     = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunValue   = 'BalanceWindow'
$VbsPath    = Join-Path $PSScriptRoot 'start-silent.vbs'

# ---------------------------------------------------------------- 联网查余额
# 官方接口：GET https://api.deepseek.com/user/balance   （Authorization: Bearer <API key>）
# 注意：DSH 凭据库里的 deepseek-account-platform token 不能用于这个接口（实测 401），
#       必须是 platform.deepseek.com 的 API key（sk- 开头）。
# key 来源按优先级：进程环境变量 DEEPSEEK_API_KEY → 小窗目录 api-key.txt → <DSH_HOME>\.env
$ApiUrl     = 'https://api.deepseek.com/user/balance'
$KeyFile    = Join-Path $PSScriptRoot 'api-key.txt'
$OnlineSecs = 60          # 联网刷新间隔（本地账本仍然每 3 秒读一次）

function Get-ApiKey {
    if ($env:DEEPSEEK_API_KEY) { return $env:DEEPSEEK_API_KEY.Trim() }
    if (Test-Path -LiteralPath $KeyFile) {
        try {
            $k = (Get-Content -LiteralPath $KeyFile -Raw -Encoding UTF8).Trim()
            if ($k) { return $k }
        } catch { }
    }
    $envFile = Join-Path $DshHome '.env'
    if (Test-Path -LiteralPath $envFile) {
        try {
            $m = [regex]::Match((Get-Content -LiteralPath $envFile -Raw), '(?m)^\s*DEEPSEEK_API_KEY\s*=\s*(.+?)\s*$')
            if ($m.Success) { return $m.Groups[1].Value.Trim().Trim('"').Trim("'") }
        } catch { }
    }
    return $null
}
$script:ApiKey = Get-ApiKey

# ---------------------------------------------------------------- 第三方源（中转站）余额
# 适用 new-api / one-api 系站点（88api 等）：它们没有官方的 /user/balance，但有 OpenAI 兼容的额度接口：
#   GET {base}/dashboard/billing/subscription                  → hard_limit_usd（总额度）
#   GET {base}/dashboard/billing/usage?start_date=…&end_date=…  → total_usage（单位：美分）
#   余额 = hard_limit_usd − total_usage / 100
# 实测 88api：这两条路由都在（不带 key 返回 401），而 /v1/user/balance 是 404。
# key 来源：进程环境变量 THIRD_API_KEY → 小窗目录 third-key.txt
# 倍率 $ThirdRate：站点控制台若按 ¥ 显示、而这里算出来是美元口径，就改成站点的汇率（如 7.3）；
#                 两边数字一致（站点额度接口本来就按站点币种折算）就保持 1.0。
$ThirdName    = '88api'
$ThirdBase    = 'https://api.88api.ai/v1'
$ThirdKeyFile = Join-Path $PSScriptRoot 'third-key.txt'
$ThirdRate    = 1.0

function Get-ThirdKey {
    if ($env:THIRD_API_KEY) { return $env:THIRD_API_KEY.Trim() }
    if (Test-Path -LiteralPath $ThirdKeyFile) {
        try {
            $k = (Get-Content -LiteralPath $ThirdKeyFile -Raw -Encoding UTF8).Trim()
            if ($k) { return $k }
        } catch { }
    }
    return $null
}
$script:ThirdKey = Get-ThirdKey

# ---------------------------------------------------------------- 状态
$script:State = [ordered]@{ left = -1.0; top = -1.0; showToday = $true; showCd = $true; petHeight = 112.0; animate = $true; online = $true; topmost = $true; third = $true }

if (Test-Path -LiteralPath $StateFile) {
    try {
        $s = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $s.left)      { $script:State.left = [double]$s.left }
        if ($null -ne $s.top)       { $script:State.top = [double]$s.top }
        if ($null -ne $s.showToday) { $script:State.showToday = [bool]$s.showToday }
        if ($null -ne $s.showCd)    { $script:State.showCd = [bool]$s.showCd }
        if ($null -ne $s.petHeight) { $script:State.petHeight = [double]$s.petHeight }
        if ($null -ne $s.animate)   { $script:State.animate = [bool]$s.animate }
        if ($null -ne $s.online)    { $script:State.online = [bool]$s.online }
        if ($null -ne $s.topmost)   { $script:State.topmost = [bool]$s.topmost }
        if ($null -ne $s.third)     { $script:State.third = [bool]$s.third }
    } catch { }
}
$script:LastBal = $null

function Save-State {
    try { ($script:State | ConvertTo-Json -Compress) | Set-Content -LiteralPath $StateFile -Encoding UTF8 } catch { }
}

# ---------------------------------------------------------------- 联网取数（不卡界面）
# 用 HttpClient 的异步任务：每次 Tick 只看任务完成没有，绝不 .Result 等待，
# 所以网络慢或超时也不会把窗口卡住。
$script:Http     = $null
$script:Task     = $null
$script:TaskAt   = [DateTime]::MinValue
$script:NetBal   = $null
$script:NetGrant = $null
$script:NetTop   = $null
$script:NetAt    = [DateTime]::MinValue
$script:NetMsg   = ''

# ---------------------------------------------------------------- 自算「今日已用」
# 余额接口不给用量，所以自己按余额变化累计：只累加【余额减少】，充值/调账（余额变大）不冲抵。
# 结果落在小窗目录的 .balance-online.json，重启接着算；跨天自动归零。
$OnlineLedger = Join-Path $PSScriptRoot '.balance-online.json'
$script:OL    = [ordered]@{ date = ''; used = 0.0; lastBal = -1.0 }
if (Test-Path -LiteralPath $OnlineLedger) {
    try {
        $o = Get-Content -LiteralPath $OnlineLedger -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $o.date)    { $script:OL.date    = [string]$o.date }
        if ($null -ne $o.used)    { $script:OL.used    = [double]$o.used }
        if ($null -ne $o.lastBal) { $script:OL.lastBal = [double]$o.lastBal }
    } catch { }
}
function Save-OL {
    try { ($script:OL | ConvertTo-Json -Compress) | Set-Content -LiteralPath $OnlineLedger -Encoding UTF8 } catch { }
}
function Update-OnlineLedger([double]$bal) {
    $today = (Get-Date).ToString('yyyy-MM-dd')
    if ($script:OL.date -ne $today) {
        # 新的一天（或第一次跑）：基准 = 当前余额
        # 今日已用先接上本地账本里已有的今日数，当天中途启动/重启不至于清零
        $seed = 0.0
        $u0 = Get-Usage
        if ($null -ne $u0 -and "$($u0.date)" -eq $today -and $null -ne $u0.todayUsage) { $seed = [double]$u0.todayUsage }
        $script:OL.date    = $today
        $script:OL.used    = $seed
        $script:OL.lastBal = $bal
        Save-OL
        return
    }
    $d = 0.0
    if ($script:OL.lastBal -ge 0) { $d = [double]$script:OL.lastBal - $bal }
    $script:OL.lastBal = $bal
    if ($d -gt 0.0005) {
        $script:OL.used = [double]$script:OL.used + $d
        Save-OL
    } elseif ($d -lt 0) {
        Save-OL            # 充值/调账：把新基准落盘
    }
}

function Start-OnlineQuery {
    if (-not $script:State.online) { return }
    if (-not $script:ApiKey) { return }
    if ($null -ne $script:Task) { return }                                  # 上一次还没回来
    if (([DateTime]::Now - $script:TaskAt).TotalSeconds -lt $OnlineSecs) { return }
    try {
        if ($null -eq $script:Http) {
            $script:Http = New-Object System.Net.Http.HttpClient
            $script:Http.Timeout = [TimeSpan]::FromSeconds(25)
            $script:Http.DefaultRequestHeaders.Authorization =
                New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $script:ApiKey)
        }
        $script:Task   = $script:Http.GetAsync($ApiUrl)     # 立即返回，不等结果
        $script:TaskAt = [DateTime]::Now
    } catch {
        $script:Task = $null
        $script:NetMsg = '发起失败 · ' + $_.Exception.Message
    }
}

function Collect-OnlineQuery {
    if ($null -eq $script:Task) { return }
    if (-not $script:Task.IsCompleted) { return }
    $t = $script:Task
    $script:Task = $null
    try {
        $resp = $t.Result
        $body = $resp.Content.ReadAsStringAsync().Result
        $code = [int]$resp.StatusCode
        if ($code -ne 200) {
            $script:NetMsg = switch ($code) {
                401 { 'API key 无效' }
                402 { '余额不足' }
                429 { '请求太频繁' }
                default { "接口返回 $code" }
            }
            $script:NetBal = $null      # 失效了就回退本地账本
            return
        }
        $j = $body | ConvertFrom-Json
        if ($j.is_available -eq $false) { $script:NetMsg = '账户不可用'; $script:NetBal = $null; return }
        $bi = $null
        if ($j.balance_infos -and @($j.balance_infos).Count -gt 0) { $bi = @($j.balance_infos)[0] }
        if ($null -eq $bi) { $script:NetMsg = '返回里没有余额字段'; $script:NetBal = $null; return }
        $script:NetBal   = [double]$bi.total_balance
        $script:NetGrant = [double]$bi.granted_balance
        $script:NetTop   = [double]$bi.topped_up_balance
        $script:NetAt    = [DateTime]::Now
        $script:NetMsg   = ''
        Update-OnlineLedger $script:NetBal        # 自己算今日已用
    } catch {
        $script:NetMsg = '联网失败 · ' + $_.Exception.Message
        try { $script:Http.Dispose() } catch { }
        $script:Http = $null            # 下次重建，避免脏连接
    }
}

# ---------------------------------------------------------------- 第三方源取数（同样不卡界面）
# 两步：先取总额度，回来后紧接着取已用量。两个请求都走同一套「Tick 里只看完成没有」的模式。
$script:Http3    = $null
$script:T3Task   = $null
$script:T3Stage  = 0             # 0 = 取总额度；1 = 取已用量
$script:T3At     = [DateTime]::MinValue
$script:T3Hard   = $null
$script:T3Used   = $null
$script:ThirdBal = $null
$script:ThirdAt  = [DateTime]::MinValue
$script:ThirdMsg = ''

function Start-ThirdQuery {
    if (-not $script:State.third) { return }
    if (-not $script:ThirdKey) { return }
    if ($null -ne $script:T3Task) { return }                                  # 上一次还没回来
    if (([DateTime]::Now - $script:T3At).TotalSeconds -lt $OnlineSecs) { return }
    try {
        if ($null -eq $script:Http3) {
            $script:Http3 = New-Object System.Net.Http.HttpClient
            $script:Http3.Timeout = [TimeSpan]::FromSeconds(25)
            $script:Http3.DefaultRequestHeaders.Authorization =
                New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $script:ThirdKey)
        }
        $script:T3Stage = 0
        $script:T3Task  = $script:Http3.GetAsync("$ThirdBase/dashboard/billing/subscription")
        $script:T3At    = [DateTime]::Now
    } catch {
        $script:T3Task   = $null
        $script:ThirdMsg = '发起失败 · ' + $_.Exception.Message
    }
}

function Collect-ThirdQuery {
    if ($null -eq $script:T3Task) { return }
    if (-not $script:T3Task.IsCompleted) { return }
    $t = $script:T3Task
    $script:T3Task = $null
    try {
        $resp = $t.Result
        $body = $resp.Content.ReadAsStringAsync().Result
        $code = [int]$resp.StatusCode
        if ($code -ne 200) {
            $script:ThirdMsg = switch ($code) {
                401 { 'API key 无效' }
                402 { '额度不足' }
                429 { '请求太频繁' }
                default { "接口返回 $code" }
            }
            $script:ThirdBal = $null          # 失效就整行显示 --
            return
        }
        $j = $body | ConvertFrom-Json

        if ($script:T3Stage -eq 0) {
            # ---- 第一步：总额度
            $hard = $null
            foreach ($p in 'hard_limit_usd', 'hard_limit', 'system_hard_limit_usd', 'soft_limit_usd') {
                if ($null -ne $j.$p) { $hard = [double]$j.$p; break }
            }
            if ($null -eq $hard) { $script:ThirdMsg = '返回里没有额度字段'; $script:ThirdBal = $null; return }
            $script:T3Hard = $hard
            # ---- 第二步：已用量。起止给足，站点若按时间段查日志也能覆盖全部历史
            $d1 = (Get-BjNow).AddYears(-3).ToString('yyyy-MM-dd')
            $d2 = (Get-BjNow).AddDays(1).ToString('yyyy-MM-dd')
            $script:T3Stage = 1
            $script:T3Task  = $script:Http3.GetAsync("$ThirdBase/dashboard/billing/usage?start_date=$d1&end_date=$d2")
            return
        }

        # ---- 第二步的返回
        $used = $null
        foreach ($p in 'total_usage', 'total_used', 'usage') {
            if ($null -ne $j.$p) { $used = [double]$j.$p; break }
        }
        if ($null -eq $used) { $script:ThirdMsg = '返回里没有用量字段'; $script:ThirdBal = $null; return }
        $script:T3Used = $used
        $bal = [double]$script:T3Hard - ($used / 100.0)        # total_usage 的单位是美分
        $bal = $bal * [double]$ThirdRate
        if ($bal -lt 0) { $bal = 0.0 }
        $script:ThirdBal = $bal
        $script:ThirdAt  = [DateTime]::Now
        $script:ThirdMsg = ''
    } catch {
        $script:ThirdMsg = '联网失败 · ' + $_.Exception.Message
        try { $script:Http3.Dispose() } catch { }
        $script:Http3 = $null                    # 下次重建，避免脏连接
    }
}

# ---------------------------------------------------------------- 读账本
function Get-Usage {
    if (-not (Test-Path -LiteralPath $UsageFile)) { return $null }
    for ($i = 0; $i -lt 3; $i++) {
        try {
            $raw = Get-Content -LiteralPath $UsageFile -Raw -Encoding UTF8
            if ([string]::IsNullOrWhiteSpace($raw)) { throw 'empty' }
            return ($raw | ConvertFrom-Json)
        } catch { Start-Sleep -Milliseconds 70 }
    }
    return $null
}

# 峰谷判定：与 dsh-whale-widget 完全同源
#   高峰 = 北京时间周一至周五（不含法定节假日）9:00-12:00、14:00-18:00
#   其余时段 —— 包括周末、调休上班的周末、法定节假日全天 —— 一律算谷
# 依据：DeepSeek 官方计费说明 + 《国务院办公厅关于 2026 年部分节假日安排的通知》
# ⚠️ 每年 11 月国务院公布次年安排后，要往这里补下一年的日期（不补就是错的）
# 只需列【放假】的日子：调休上班日全部落在周末，本来就按谷价算，不用单列。
$HolidayValley = @(
    '2026-01-01', '2026-01-02', '2026-01-03',                                        # 元旦
    '2026-02-15', '2026-02-16', '2026-02-17', '2026-02-18', '2026-02-19',            # 春节 2/15-2/23
    '2026-02-20', '2026-02-21', '2026-02-22', '2026-02-23',
    '2026-04-04', '2026-04-05', '2026-04-06',                                        # 清明
    '2026-05-01', '2026-05-02', '2026-05-03', '2026-05-04', '2026-05-05',            # 劳动节
    '2026-06-19', '2026-06-20', '2026-06-21',                                        # 端午
    '2026-09-25', '2026-09-26', '2026-09-27',                                        # 中秋
    '2026-10-01', '2026-10-02', '2026-10-03', '2026-10-04', '2026-10-05',            # 国庆 10/1-10/7
    '2026-10-06', '2026-10-07'
)
$PeakTip = '高峰：周一至周五（非法定节假日）9:00-12:00、14:00-18:00；周末与法定节假日全天算谷'

# 一律按北京时间算，不受本机时区影响（与挂件同源）
function Get-BjNow { return [DateTime]::UtcNow.AddHours(8) }

function Test-BjPeak([DateTime]$bj) {
    if ($bj.DayOfWeek -eq 'Saturday' -or $bj.DayOfWeek -eq 'Sunday') { return $false }   # 周末全天谷价
    if ($HolidayValley -contains $bj.ToString('yyyy-MM-dd')) { return $false }           # 法定节假日全天谷价
    $h = $bj.Hour + $bj.Minute / 60.0
    return (($h -ge 9 -and $h -lt 12) -or ($h -ge 14 -and $h -lt 18))
}
function Get-PeakTag {
    if (Test-BjPeak (Get-BjNow)) { return '峰' }
    return '谷'
}

# 下一个峰谷切换时刻（与挂件的 nextPeakChangeAt 同源）：
# 只需扫北京时间的小时边界 0/9/12/14/18 点。最长假期（春节 9 天）也只到第 9 天，扫 15 天留足余量。
function Get-NextPeakChange([DateTime]$bj) {
    $cur  = Test-BjPeak $bj
    $day0 = $bj.Date                      # 北京当日 00:00
    foreach ($d in 0..14) {
        foreach ($edge in @(0, 9, 12, 14, 18)) {
            $cand = $day0.AddDays($d).AddHours($edge)
            if ($cand -le $bj) { continue }
            if ((Test-BjPeak $cand) -ne $cur) { return $cand }
        }
    }
    return $null
}

# 倒计时文案：还没到高峰就说「距高峰」，正在高峰就说「距谷价」
function Get-PeakCountdown {
    $now = Get-BjNow
    $next = Get-NextPeakChange $now
    if ($null -eq $next) { return '' }
    $ts = $next - $now
    if ($ts.TotalSeconds -le 0) { return '' }
    $word = if (Test-BjPeak $now) { '距谷价' } else { '距高峰' }
    if ($ts.TotalHours -ge 1) {
        return '{0} {1:N0} 时 {2:N0} 分' -f $word, [Math]::Floor($ts.TotalHours), $ts.Minutes
    }
    return '{0} {1:N0} 分' -f $word, [Math]::Ceiling($ts.TotalMinutes)
}

# ---------------------------------------------------------------- 调色
function C([int]$a, [int]$r, [int]$g, [int]$b) {
    [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromArgb($a, $r, $g, $b))
}

$clrText    = C 255 235 242 255
$clrDim     = C 255 150 168 194
$clrDimmer  = C 255 108 124 148
$clrCardBg  = C 228  22  28  40
$clrCardBd  = C  60 255 255 255
$clrBodyA   = [System.Windows.Media.Color]::FromArgb(255,  96, 165, 250)
$clrBodyB   = [System.Windows.Media.Color]::FromArgb(255,  37,  99, 235)

# ---------------------------------------------------------------- 兜底形象：小鲸鱼（代码绘制，不含第三方素材）
$whale = [System.Windows.Controls.Canvas]::new()
$whale.Width = 74; $whale.Height = 56
$whale.VerticalAlignment = 'Center'

function Add-Path($canvas, [string]$d, $fill, $stroke, [double]$thick) {
    $p = [System.Windows.Shapes.Path]::new()
    $p.Data = [System.Windows.Media.Geometry]::Parse($d)
    if ($null -ne $fill) { $p.Fill = $fill }
    if ($null -ne $stroke) {
        $p.Stroke = $stroke; $p.StrokeThickness = $thick
        $p.StrokeStartLineCap = 'Round'; $p.StrokeEndLineCap = 'Round'
    }
    [void]$canvas.Children.Add($p)
    return $p
}
function Add-Dot($canvas, [double]$x, [double]$y, [double]$w, [double]$h, $fill) {
    $e = [System.Windows.Shapes.Ellipse]::new()
    $e.Width = $w; $e.Height = $h; $e.Fill = $fill
    [System.Windows.Controls.Canvas]::SetLeft($e, $x)
    [System.Windows.Controls.Canvas]::SetTop($e, $y)
    [void]$canvas.Children.Add($e)
    return $e
}

$grad = [System.Windows.Media.LinearGradientBrush]::new()
$grad.StartPoint = '0,0'; $grad.EndPoint = '0.7,1'
[void]$grad.GradientStops.Add([System.Windows.Media.GradientStop]::new($clrBodyA, 0.0))
[void]$grad.GradientStops.Add([System.Windows.Media.GradientStop]::new($clrBodyB, 1.0))

# 尾巴
Add-Path $whale 'M 20,32 C 14,27 9,22 3,16 C 5,25 5,39 3,48 C 9,42 14,37 20,32 Z' $grad $null 0 | Out-Null
# 身体
$body = Add-Path $whale 'M 20,32 C 20,19 34,12 48,12 C 62,12 70,20 70,32 C 70,44 62,52 48,52 C 34,52 20,45 20,32 Z' $grad $null 0
# 肚皮
Add-Path $whale 'M 26,38 C 32,48 62,48 68,38 C 68,45 61,51 47,51 C 33,51 26,45 26,38 Z' (C 190 96 165 250) $null 0 | Out-Null
# 眼睛 + 高光
Add-Dot $whale 53 25 6 6 (C 255 17 24 39) | Out-Null
Add-Dot $whale 54.6 26.4 2 2 (C 255 255 255 255) | Out-Null
# 笑弧
Add-Path $whale 'M 56,36 C 53,40 47,40 44,37' $null (C 255 17 24 39) 1.6 | Out-Null
# 喷水
Add-Dot $whale 40 1 4 4 (C 210 147 197 253) | Out-Null
Add-Dot $whale 47 4 2.6 2.6 (C 170 147 197 253) | Out-Null
Add-Dot $whale 34 4 2.2 2.2 (C 150 147 197 253) | Out-Null

# ---------------------------------------------------------------- 宠物形象
# 同目录下若有 pet.png / pet.jpg / pet.gif / pet.bmp 就用它（人形立绘）；
# 没有才回退到上面代码画的小鲸鱼。想换形象：把图命名为 pet.png 丢进本目录即可。
$PetImage = $null
$PetFile  = $null
foreach ($ext in @('.png', '.jpg', '.jpeg', '.gif', '.bmp')) {
    $cand = Join-Path $PSScriptRoot ('pet' + $ext)
    if (Test-Path -LiteralPath $cand) { $PetFile = $cand; break }
}

$petHost = [System.Windows.Controls.StackPanel]::new()
$petHost.VerticalAlignment = 'Bottom'
$petHost.HorizontalAlignment = 'Left'
# 内层容器：专负责「互动反应」（弹跳/抖动），与待机的浮动互不打架
$react = [System.Windows.Controls.StackPanel]::new()
$react.VerticalAlignment = 'Center'

if ($PetFile) {
    try {
        $bmp = [System.Windows.Media.Imaging.BitmapImage]::new()
        $bmp.BeginInit()
        $bmp.UriSource = [Uri]::new($PetFile)
        $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmp.EndInit()
        $bmp.Freeze()
        # 记住宽高比，用来算「动画余量」和与方框的叠压量
        if ($bmp.PixelHeight -gt 0) { $script:PetAspect = $bmp.PixelWidth / [double]$bmp.PixelHeight }
        $PetImage = [System.Windows.Controls.Image]::new()
        $PetImage.Source = $bmp
        $PetImage.Stretch = 'Uniform'
        $PetImage.Height = [double]$script:State.petHeight
        [void]$react.Children.Add($PetImage)
    } catch { $PetImage = $null }
}
if (-not $PetImage) { [void]$react.Children.Add($whale) }
[void]$petHost.Children.Add($react)

# ------------------------------------------------ 互动反应
# Scale 做弹跳/拾头，Translate.X 做抖动，Translate.Y 做小跳；三者各用各的属性，不打架。
$reactST = [System.Windows.Media.ScaleTransform]::new(1.0, 1.0)
$reactTT = [System.Windows.Media.TranslateTransform]::new(0, 0)
$reactGroup = [System.Windows.Media.TransformGroup]::new()
[void]$reactGroup.Children.Add($reactST)
[void]$reactGroup.Children.Add($reactTT)
$react.RenderTransform = $reactGroup
$react.RenderTransformOrigin = [System.Windows.Point]::new(0.5, 1.0)

# 关键帧小工具：-frames 必须是“数组的数组”@(@(值,秒), @(值,秒), ...)
# 注意要用具名参数 -frames，否则 PowerShell 会把外数组展开成多个位置参数。
function New-KeyAnim($frames) {
    $a = [System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames]::new()
    foreach ($f in $frames) {
        $kf = [System.Windows.Media.Animation.EasingDoubleKeyFrame]::new([double]$f[0], [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromSeconds([double]$f[1])))
        $ez = [System.Windows.Media.Animation.SineEase]::new()
        $ez.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseInOut
        $kf.EasingFunction = $ez
        [void]$a.KeyFrames.Add($kf)
    }
    return $a
}
function Invoke-Bounce {   # 点击：原地弹一下（也是绕脚底，不飞起来）
    if (-not $script:State.animate) { return }
    $reactST.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, (New-KeyAnim -frames @(@(1.00, 0.00), @(0.90, 0.08), @(1.10, 0.22), @(0.96, 0.34), @(1.00, 0.50))))
    $reactST.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, (New-KeyAnim -frames @(@(1.00, 0.00), @(0.90, 0.08), @(1.10, 0.22), @(0.96, 0.34), @(1.00, 0.50))))
}
function Invoke-Perk {     # 悬停：站直一点（拉伸，不抬脚）
    if (-not $script:State.animate) { return }
    $reactST.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, (New-KeyAnim -frames @(@(1.00, 0.00), @(1.06, 0.16), @(1.00, 0.32))))
    $reactST.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, (New-KeyAnim -frames @(@(1.00, 0.00), @(1.06, 0.16), @(1.00, 0.32))))
}
function Invoke-Shake {    # 余额变化：左右抖一下
    if (-not $script:State.animate) { return }
    $reactTT.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, (New-KeyAnim -frames @(@(0, 0.00), @(-4, 0.07), @(4, 0.19), @(-2.5, 0.31), @(2.5, 0.43), @(0, 0.56))))
}

# ---------------------------------------------------------------- 待机动画
# 呼吸式起伏 + 极轻微摇摆，两个周期故意不成整数比，叠起来像“活的”。
# 关键：起伏用【绕脚底缩放】而不是上下平移 —— 平移会把两只脚一起抬起来，
#       看着像飘着的气球；缩放以脚底为轴心，脚钉在原地，只有脚以上在动。
# 只用 RenderTransform（不参与布局），所以窗口尺寸不会跟着抖。
$swayST    = [System.Windows.Media.ScaleTransform]::new(1.0, 1.0)
$swayRT    = [System.Windows.Media.RotateTransform]::new()
$swayGroup = [System.Windows.Media.TransformGroup]::new()
[void]$swayGroup.Children.Add($swayST)
[void]$swayGroup.Children.Add($swayRT)
$petHost.RenderTransform = $swayGroup
$petHost.RenderTransformOrigin = [System.Windows.Point]::new(0.5, 1.0)   # 轴心 = 脚底中点

function Start-Sway {
    $ease = [System.Windows.Media.Animation.SineEase]::new()
    $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseInOut

    # 竖向压 3%（144px 的人 ≈ 头顶上下 4.3px），脚底不动
    $aY = [System.Windows.Media.Animation.DoubleAnimation]::new(1.0, 0.97, [System.Windows.Duration]::new([TimeSpan]::FromSeconds(2.4)))
    $aY.AutoReverse    = $true
    $aY.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $aY.EasingFunction = $ease
    $swayST.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $aY)

    # 压扁时横向微胀一点，看起来像在「呼吸」而不是被压瘪
    $aX = [System.Windows.Media.Animation.DoubleAnimation]::new(1.0, 1.012, [System.Windows.Duration]::new([TimeSpan]::FromSeconds(2.4)))
    $aX.AutoReverse    = $true
    $aX.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $aX.EasingFunction = $ease
    $swayST.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $aX)

    # 摇头：也是绕脚底，所以身体摆、脚不动
    $aR = [System.Windows.Media.Animation.DoubleAnimation]::new(-1.0, 1.0, [System.Windows.Duration]::new([TimeSpan]::FromSeconds(3.7)))
    $aR.AutoReverse    = $true
    $aR.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $aR.EasingFunction = $ease
    $swayRT.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $aR)
}
function Stop-Sway {
    $swayST.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $null)
    $swayST.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $null)
    $swayRT.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $null)
}

# ---------------------------------------------------------------- 文本
$lblBal = [System.Windows.Controls.TextBlock]::new()
$lblBal.Text = '¥ --'
$lblBal.FontSize = 21; $lblBal.FontWeight = 'Bold'
$lblBal.Foreground = $clrText
$lblBal.FontFamily = [System.Windows.Media.FontFamily]::new('Microsoft YaHei UI, Segoe UI')

# 第三方源（88api 等）余额行：没配 key 或关掉时整行折叠，不占位置
$lblThird = [System.Windows.Controls.TextBlock]::new()
$lblThird.Text = ''
$lblThird.FontSize = 12.5; $lblThird.FontWeight = 'SemiBold'
$lblThird.Margin = [System.Windows.Thickness]::new(1, 1, 0, 0)
$lblThird.Foreground = $clrDim
$lblThird.Visibility = 'Collapsed'
$lblThird.FontFamily = $lblBal.FontFamily

$lblToday = [System.Windows.Controls.TextBlock]::new()
$lblToday.Text = '读取中…'
$lblToday.FontSize = 11.5; $lblToday.Margin = [System.Windows.Thickness]::new(1, 2, 0, 0)
$lblToday.Foreground = $clrDim
$lblToday.FontFamily = $lblBal.FontFamily

$lblAge = [System.Windows.Controls.TextBlock]::new()
$lblAge.Text = ''
$lblAge.FontSize = 10; $lblAge.Margin = [System.Windows.Thickness]::new(1, 1, 0, 0)
$lblAge.Foreground = $clrDimmer
$lblAge.FontFamily = $lblBal.FontFamily

$lblCd = [System.Windows.Controls.TextBlock]::new()
$lblCd.Text = ''
$lblCd.FontSize = 11.5; $lblCd.Margin = [System.Windows.Thickness]::new(1, 2, 0, 0)
$lblCd.Foreground = $clrDim
$lblCd.FontFamily = $lblBal.FontFamily

$texts = [System.Windows.Controls.StackPanel]::new()
$texts.VerticalAlignment = 'Center'
[void]$texts.Children.Add($lblBal)
[void]$texts.Children.Add($lblThird)
[void]$texts.Children.Add($lblToday)
[void]$texts.Children.Add($lblCd)
[void]$texts.Children.Add($lblAge)

# 信息框：只包文字了 → 方框明显变小（人物不再撑大方框）
$card = [System.Windows.Controls.Border]::new()
$card.CornerRadius = [System.Windows.CornerRadius]::new(12)
$card.Background = $clrCardBg
$card.BorderBrush = $clrCardBd
$card.BorderThickness = [System.Windows.Thickness]::new(1)
$card.Padding = [System.Windows.Thickness]::new(21, 7, 14, 7)
$card.Child = $texts
$card.HorizontalAlignment = 'Right'
$card.VerticalAlignment = 'Bottom'

# 版式：人物在左、方框在右，两者底边对齐；人物比方框高，头和上身就露在框外。
# 人物用负的右外边距往右压住方框左边一点，做出「人站在牌子前面」的层次。
$petHost.Margin = [System.Windows.Thickness]::new(0, 0, -13, 0)

$root = [System.Windows.Controls.Grid]::new()
$root.ClipToBounds = $false
[void]$root.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]::new())
[void]$root.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]::new())
# 先加方框、后加人物 → 人物画在方框上面（压住方框左边）
[System.Windows.Controls.Grid]::SetColumn($card, 1)
[void]$root.Children.Add($card)
[System.Windows.Controls.Grid]::SetColumn($petHost, 0)
[void]$root.Children.Add($petHost)

# 最外层只负责「留动画余量」：弹跳放大 10%、摇摆 ±1° 都要地方，否则头会被窗口切平。
$frame = [System.Windows.Controls.Border]::new()
$frame.ClipToBounds = $false
$frame.Child = $root

function Update-PetRoom {
    $h = 56.0; $w = 74.0
    if ($PetImage) { $h = [double]$script:State.petHeight; $w = $h * $script:PetAspect }
    $padX = [Math]::Round($w * 0.06 + 5)
    $padT = [Math]::Round($h * 0.12 + 7)
    $frame.Padding = [System.Windows.Thickness]::new($padX, $padT, $padX, 3)
}
Update-PetRoom

$win = [System.Windows.Window]::new()
$win.WindowStyle = 'None'
$win.AllowsTransparency = $true
# 背景留空 → 方框和人物以外的透明区域点得过去（不会挡住后面的东西）
$win.Background = $null
$win.Topmost = [bool]$script:State.topmost
$win.ShowInTaskbar = $false
$win.ShowActivated = $false
$win.ResizeMode = 'NoResize'
$win.SizeToContent = 'WidthAndHeight'
$win.WindowStartupLocation = 'Manual'
$win.Title = '余额小窗'
$win.Content = $frame
$win.Cursor = [System.Windows.Input.Cursors]::SizeAll

# ---------------------------------------------------------------- 刷新
function Update-Ui {
    Start-OnlineQuery
    Collect-OnlineQuery
    Start-ThirdQuery
    Collect-ThirdQuery

    $u = Get-Usage

    # ---- 余额：联网优先；没配 key 或联网失败就回退到本地账本
    $bal = $null
    if ($null -ne $script:NetBal) { $bal = $script:NetBal }
    elseif ($null -ne $u -and $null -ne $u.lastBalance) { $bal = [double]$u.lastBalance }

    if ($null -ne $bal) {
        $lblBal.Text = '¥ {0:N2}' -f $bal
        if     ($bal -lt 3)  { $lblBal.Foreground = (C 255 255 122 122) }
        elseif ($bal -lt 10) { $lblBal.Foreground = (C 255 255 196  77) }
        else                 { $lblBal.Foreground = $clrText }
        if ($null -ne $script:NetGrant) {
            $lblBal.ToolTip = '赠送 ¥{0:N2} · 充值 ¥{1:N2}' -f $script:NetGrant, $script:NetTop
        }
    } else {
        $lblBal.Text = '¥ --'
        $lblBal.Foreground = $clrText
        $lblBal.ToolTip = $null
    }

    # 余额变化 ≥ 5 分钱 → 抖一下（首次读数不算）
    if ($null -ne $bal) {
        if ($null -ne $script:LastBal -and [Math]::Abs($bal - $script:LastBal) -ge 0.05) { Invoke-Shake }
        $script:LastBal = $bal
    }

    # ---- 第三方源余额（88api 等）：没配 key / 关掉 → 整行折叠
    if ($script:ThirdKey -and $script:State.third) {
        $lblThird.Visibility = 'Visible'
        if ($null -ne $script:ThirdBal) {
            $lblThird.Text = '{0} ¥ {1:N2}' -f $ThirdName, [double]$script:ThirdBal
            if ([double]$script:ThirdBal -lt 3) { $lblThird.Foreground = (C 255 255 196 77) }
            else                                { $lblThird.Foreground = $clrDim }
            $sec3 = ([DateTime]::Now - $script:ThirdAt).TotalSeconds
            $h3 = [double]$script:T3Hard
            $u3 = [double]$script:T3Used / 100.0
            $tip3 = '{0} 剩余额度 = 总额度 {1:N2} − 已用 {2:N2}' -f $ThirdName, $h3, $u3
            if     ($sec3 -lt 90)   { $tip3 = $tip3 + "`n{0:N0} 秒前取的数" -f $sec3 }
            elseif ($sec3 -lt 3600) { $tip3 = $tip3 + "`n{0:N0} 分钟前取的数" -f ($sec3 / 60) }
            else                    { $tip3 = $tip3 + "`n{0:N0} 小时前取的数" -f ($sec3 / 3600) }
            $lblThird.ToolTip = $tip3
        } else {
            $lblThird.Text = '{0} ¥ --' -f $ThirdName
            $lblThird.Foreground = $clrDimmer
            if ($script:ThirdMsg) { $lblThird.ToolTip = $script:ThirdMsg }
            else { $lblThird.ToolTip = '还没取到 · 在 third-key.txt 里填 88api 的 sk- key' }
        }
    } else {
        $lblThird.Visibility = 'Collapsed'
        $lblThird.ToolTip = $null
    }

    # ---- 今日已用：联网时按余额变化自己算；否则用本地账本
    if ($script:State.showToday) {
        $todayTxt = '今日 —'
        $todayTip = $null
        if ($script:OL.date -eq (Get-Date).ToString('yyyy-MM-dd')) {
            $todayTxt = '今日 ¥ {0:N2}' -f [double]$script:OL.used
            $todayTip = '按余额变化自己算：只累加余额减少，充值/调账不冲抵'
        } elseif ($null -ne $u) {
            if ($null -ne $u.todayUsage) { $todayTxt = '今日 ¥ {0:N2}' -f [double]$u.todayUsage }
            if ("$($u.date)" -ne (Get-Date).ToString('yyyy-MM-dd')) { $todayTxt = "今日 —（账本停在 $($u.date)）" }
            $todayTip = '来自本地账本（dsh-whale-widget）'
        } else {
            $todayTxt = '今日 — · 没找到本地账本'
        }
        $lblToday.Text = "$todayTxt · $(Get-PeakTag)"
        if ($todayTip) { $lblToday.ToolTip = "$todayTip`n$PeakTip" } else { $lblToday.ToolTip = $PeakTip }
    } else {
        $lblToday.Text = "峰谷 $(Get-PeakTag)"
        $lblToday.ToolTip = $PeakTip
    }

    # ---- 峰谷倒计时
    if ($script:State.showCd) { $lblCd.Text = (Get-PeakCountdown) } else { $lblCd.Text = '' }

    # ---- 末行：数据来源 + 新鲜度
    $ageTxt = ''
    if ($null -ne $script:NetBal) {
        $sec = ([DateTime]::Now - $script:NetAt).TotalSeconds
        if     ($sec -lt 90)   { $ageTxt = '在线 · {0:N0} 秒前' -f $sec }
        elseif ($sec -lt 3600) { $ageTxt = '在线 · {0:N0} 分钟前' -f ($sec / 60) }
        else                   { $ageTxt = '在线 · {0:N0} 小时前' -f ($sec / 3600) }
        if ($script:NetMsg) { $ageTxt = "$($script:NetMsg) · 用的是上次读数" }
    } elseif ($null -ne $u) {
        try {
            $a = (Get-Date) - (Get-Item -LiteralPath $UsageFile).LastWriteTime
            if     ($a.TotalSeconds -lt 90) { $ageTxt = '本地 · {0:N0} 秒前' -f $a.TotalSeconds }
            elseif ($a.TotalMinutes -lt 60) { $ageTxt = '本地 · {0:N0} 分钟前' -f $a.TotalMinutes }
            else                            { $ageTxt = '本地 · {0:N0} 小时前 · DSH 没开' -f $a.TotalHours }
        } catch { }
    } else {
        $ageTxt = '没有数据 · 请启动 DSH 或配置 api-key.txt'
    }
    if (-not $script:ApiKey) {
        $ageTxt = '本地 · 未配 API key（api-key.txt）'
    } elseif (-not $script:State.online) {
        $ageTxt = '本地 · 联网已关'
    } elseif ($script:NetMsg -and $null -eq $script:NetBal) {
        $ageTxt = '联网失败 · ' + $script:NetMsg
    }
    $lblAge.Text = $ageTxt
}

$timer = [System.Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromSeconds(3)
$timer.Add_Tick({ Update-Ui })

# ---------------------------------------------------------------- 拖动 / 菜单位置
$win.Add_MouseLeftButtonDown({
    $x0 = $win.Left; $y0 = $win.Top
    try { $win.DragMove() } catch { }
    # 拖动幅度小于 3px 视为单击（容忍手抖）→ 弹一下
    if ([Math]::Abs($win.Left - $x0) -lt 3.0 -and [Math]::Abs($win.Top - $y0) -lt 3.0) { Invoke-Bounce }
})
$petHost.Add_MouseEnter({ Invoke-Perk })

# ---------------------------------------------------------------- 右键菜单
function Test-Autostart {
    try { return ($null -ne (Get-ItemProperty -Path $RunKey -Name $RunValue -ErrorAction Stop)) }
    catch { return $false }
}
function Set-Autostart([bool]$on) {
    try {
        if ($on) {
            if (-not (Test-Path -LiteralPath $VbsPath)) { return }
            if (-not (Test-Path -Path $RunKey)) { New-Item -Path $RunKey -Force | Out-Null }
            Set-ItemProperty -Path $RunKey -Name $RunValue -Value ('wscript.exe "{0}"' -f $VbsPath)
        } else {
            Remove-ItemProperty -Path $RunKey -Name $RunValue -ErrorAction SilentlyContinue
        }
    } catch { }
}

$miRefresh = [System.Windows.Controls.MenuItem]::new(); $miRefresh.Header = '立即刷新'
$miToday   = [System.Windows.Controls.MenuItem]::new(); $miToday.Header = '显示今日已用'
$miToday.IsCheckable = $true; $miToday.IsChecked = [bool]$script:State.showToday
$miStart   = [System.Windows.Controls.MenuItem]::new(); $miStart.Header = '开机自动启动'
$miStart.IsCheckable = $true; $miStart.IsChecked = (Test-Autostart)
$miWhere   = [System.Windows.Controls.MenuItem]::new(); $miWhere.Header = '打开账本文件夹'
$miDir     = [System.Windows.Controls.MenuItem]::new(); $miDir.Header = '打开小窗目录（放 api-key.txt）'
$miQuit    = [System.Windows.Controls.MenuItem]::new(); $miQuit.Header = '退出'

# 联网查余额（没配 key 就置灰）
$miOnline = [System.Windows.Controls.MenuItem]::new()
$miOnline.IsCheckable = $true; $miOnline.IsChecked = [bool]$script:State.online
if (-not $script:ApiKey) {
    $miOnline.Header = '联网查余额（未配置 api-key.txt）'
    $miOnline.IsEnabled = $false
} else {
    $miOnline.Header = '联网查余额（每 60 秒）'
}
$miOnline.Add_Click({
    $script:State.online = [bool]$miOnline.IsChecked
    if ($script:State.online) { $script:TaskAt = [DateTime]::MinValue }
    else { $script:NetBal = $null; $script:NetMsg = '' }
    Save-State; Update-Ui
})

# 第三方源（88api 等）：开关 + 打开 key 文件
$miThird = [System.Windows.Controls.MenuItem]::new()
$miThird.IsCheckable = $true; $miThird.IsChecked = [bool]$script:State.third
if ($script:ThirdKey) {
    $miThird.Header = '显示第三方余额（{0}，每 60 秒）' -f $ThirdName
} else {
    $miThird.Header = '显示第三方余额（未配置 third-key.txt）'
}
$miThird.Add_Click({
    $script:State.third = [bool]$miThird.IsChecked
    if ($script:State.third) { $script:T3At = [DateTime]::MinValue }
    else { $script:ThirdBal = $null; $script:ThirdMsg = '' }
    Save-State; Update-Ui
})

$miThirdKey = [System.Windows.Controls.MenuItem]::new()
$miThirdKey.Header = '打开第三方 key 文件（third-key.txt）'
$miThirdKey.Add_Click({
    if (Test-Path -LiteralPath $ThirdKeyFile) {
        Start-Process notepad.exe $ThirdKeyFile
    } else {
        [void][System.Windows.MessageBox]::Show("请在该目录新建 third-key.txt，把 $ThirdName 的 sk- key 粘进去（文件里只放 key）：`n$PSScriptRoot", '第三方源')
        Start-Process explorer.exe $PSScriptRoot
    }
})

$miAnim = [System.Windows.Controls.MenuItem]::new(); $miAnim.Header = '待机动画与互动（晃动 / 弹跳）'
$miAnim.IsCheckable = $true; $miAnim.IsChecked = [bool]$script:State.animate
$miAnim.Add_Click({
    $script:State.animate = [bool]$miAnim.IsChecked
    if ($script:State.animate) { Start-Sway } else { Stop-Sway }
    Save-State
})

# 形象大小（仅在用了 pet.* 图片时可用）
$miPet = [System.Windows.Controls.MenuItem]::new(); $miPet.Header = '形象大小'
if (-not $PetImage) {
    $miPet.IsEnabled = $false
} else {
    foreach ($preset in @(@('小', 80), @('中', 112), @('大', 144), @('特大', 190))) {
        $mi = [System.Windows.Controls.MenuItem]::new()
        $mi.Header = '{0}   ({1} px)' -f $preset[0], $preset[1]
        $mi.Tag = [double]$preset[1]
        $mi.IsCheckable = $true
        $mi.IsChecked = ([double]$script:State.petHeight -eq [double]$preset[1])
        $mi.Add_Click({
            $script:State.petHeight = [double]$this.Tag
            if ($PetImage) { $PetImage.Height = $script:State.petHeight }
            Update-PetRoom
            Save-State
            foreach ($sib in $miPet.Items) {
                if ($sib -is [System.Windows.Controls.MenuItem]) { $sib.IsChecked = ([double]$sib.Tag -eq $script:State.petHeight) }
            }
        })
        [void]$miPet.Items.Add($mi)
    }
}

$miRefresh.Add_Click({ $script:TaskAt = [DateTime]::MinValue; $script:T3At = [DateTime]::MinValue; Update-Ui })
$miToday.Add_Click({
    $script:State.showToday = [bool]$miToday.IsChecked
    Save-State; Update-Ui
})

$miCd = [System.Windows.Controls.MenuItem]::new(); $miCd.Header = '显示峰谷倒计时'
$miCd.IsCheckable = $true; $miCd.IsChecked = [bool]$script:State.showCd
$miCd.Add_Click({
    $script:State.showCd = [bool]$miCd.IsChecked
    Save-State; Update-Ui
})

# 置顶开关（关掉就能被其他窗口盖住）
$miTop = [System.Windows.Controls.MenuItem]::new(); $miTop.Header = '窗口置顶'
$miTop.IsCheckable = $true; $miTop.IsChecked = [bool]$script:State.topmost
$miTop.Add_Click({
    $script:State.topmost = [bool]$miTop.IsChecked
    $win.Topmost = $script:State.topmost
    Save-State
})
$miStart.Add_Click({
    Set-Autostart ([bool]$miStart.IsChecked)
    $miStart.IsChecked = (Test-Autostart)
})
$miWhere.Add_Click({ Start-Process explorer.exe (Split-Path -Parent $UsageFile) })
$miDir.Add_Click({ Start-Process explorer.exe $PSScriptRoot })
$miQuit.Add_Click({
    $script:State.left = $win.Left; $script:State.top = $win.Top
    Save-State; Save-OL; $timer.Stop(); $win.Close()
})

$menu = [System.Windows.Controls.ContextMenu]::new()
[void]$menu.Items.Add($miRefresh)
[void]$menu.Items.Add($miToday)
[void]$menu.Items.Add($miCd)
[void]$menu.Items.Add($miOnline)
[void]$menu.Items.Add($miThird)
[void]$menu.Items.Add($miThirdKey)
[void]$menu.Items.Add($miAnim)
[void]$menu.Items.Add($miPet)
[void]$menu.Items.Add($miTop)
[void]$menu.Items.Add([System.Windows.Controls.Separator]::new())
[void]$menu.Items.Add($miStart)
[void]$menu.Items.Add($miWhere)
[void]$menu.Items.Add($miDir)
[void]$menu.Items.Add([System.Windows.Controls.Separator]::new())
[void]$menu.Items.Add($miQuit)
$card.ContextMenu = $menu
$win.ContextMenu = $menu

# ---------------------------------------------------------------- 起点 / 收尾
$win.Add_Loaded({
    if ($script:State.left -ge 0 -and $script:State.top -ge 0) {
        $win.Left = $script:State.left
        $win.Top  = $script:State.top
    } else {
        # SizeToContent 的尺寸要等布局跑完才准，所以延后到 ContextIdle 再定位
        $win.Dispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::ContextIdle,
            [Action] {
                $win.UpdateLayout()
                $wa = [System.Windows.SystemParameters]::WorkArea
                $win.Left = [Math]::Max($wa.Left, $wa.Right  - $win.ActualWidth  - 28)
                $win.Top  = [Math]::Max($wa.Top,  $wa.Bottom - $win.ActualHeight - 28)
            }) | Out-Null
    }
    if ($script:State.animate) { Start-Sway }
    Update-Ui
    $timer.Start()
})

$win.Add_Closing({
    $script:State.left = $win.Left; $script:State.top = $win.Top
    Save-State
    Save-OL
})

[void]$win.ShowDialog()
