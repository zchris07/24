# Builds TwentyFour.rbxlx (open it in Roblox Studio) from the src folder.
#   powershell -ExecutionPolicy Bypass -File tools\build.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$src = Join-Path $root 'src'
$out = Join-Path $root 'TwentyFour.rbxlx'

$script:ref = 0
function NextRef { $script:ref++; return "RBX$($script:ref.ToString('X8'))" }

function Esc([string]$s) {
  return [System.Security.SecurityElement]::Escape($s)
}

function ReadSource([string]$path) {
  $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
  $text = $text -replace "`r`n", "`n"
  # a CDATA section can't contain its own terminator
  return $text.Replace(']]>', ']]]]><![CDATA[>')
}

function ScriptItem([string]$class, [string]$name, [string]$path, [string]$children = '') {
  $r = NextRef
  $body = ReadSource $path
  return @"
<Item class="$class" referent="$r">
<Properties>
<string name="Name">$(Esc $name)</string>
<bool name="Disabled">false</bool>
<ProtectedString name="Source"><![CDATA[$body]]></ProtectedString>
</Properties>
$children</Item>
"@
}

function Container([string]$class, [string]$name, [string]$children, [string]$extraProps = '') {
  $r = NextRef
  return @"
<Item class="$class" referent="$r">
<Properties>
<string name="Name">$(Esc $name)</string>
$extraProps</Properties>
$children</Item>
"@
}

# shared modules -> ReplicatedStorage.TwentyFour
$shared = ''
foreach ($f in Get-ChildItem (Join-Path $src 'shared') -Filter *.luau | Sort-Object Name) {
  $shared += ScriptItem 'ModuleScript' $f.BaseName $f.FullName
}
$replicated = Container 'ReplicatedStorage' 'ReplicatedStorage' (Container 'Folder' 'TwentyFour' $shared)

# server script
$serverFile = Join-Path $src 'server\TwentyFourServer.server.luau'
$server = Container 'ServerScriptService' 'ServerScriptService' (ScriptItem 'Script' 'TwentyFourServer' $serverFile)

# client: LocalScript with a Modules folder
$modules = ''
foreach ($f in Get-ChildItem (Join-Path $src 'client\TwentyFourClient\Modules') -Filter *.luau | Sort-Object Name) {
  $modules += ScriptItem 'ModuleScript' $f.BaseName $f.FullName
}
$clientFile = Join-Path $src 'client\TwentyFourClient\init.client.luau'
$client = ScriptItem 'LocalScript' 'TwentyFourClient' $clientFile (Container 'Folder' 'Modules' $modules)
$starterPlayer = Container 'StarterPlayer' 'StarterPlayer' (Container 'StarterPlayerScripts' 'StarterPlayerScripts' $client)

$players = Container 'Players' 'Players' '' "<bool name=`"CharacterAutoLoads`">false</bool>`n"

$xml = @"
<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">
<External>null</External>
<External>nil</External>
$players$replicated$server$starterPlayer</roblox>
"@

$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($out, ($xml -replace "`r`n", "`n"), $utf8)

# sanity check: must be well-formed XML
[xml]$check = [System.IO.File]::ReadAllText($out, $utf8)
$scripts = $check.SelectNodes('//Item[@class="ModuleScript" or @class="Script" or @class="LocalScript"]')
Write-Host "Built $out ($([math]::Round((Get-Item $out).Length / 1KB)) KB, $($scripts.Count) scripts)"
