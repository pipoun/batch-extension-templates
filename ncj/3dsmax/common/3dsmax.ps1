param (
    [int]$start = 1,
    [int]$end = 1,
    [string]$outputName = "images\image.jpg",
    [int]$width = 800,
    [int]$height = 600,
    [string]$sceneFile,
    [int]$nodeCount = 1,
    [switch]$dr,
    [string]$renderer = "vray",
    [string]$irradianceMap = "",
    [string]$pathFile = $null
)

function SetupDistributedRendering
{
    Write-Error "Setting up DR..."
    
    $port = 20207
    $vraydr_file = "vray_dr.cfg"
    $vrayrtdr_file = "vrayrt_dr.cfg"
    $hosts = $env:AZ_BATCH_HOST_LIST.Split(",")

    if ($hosts.Count -ne $nodeCount) {
        Write-Error "Host count $hosts.Count must equal nodeCount $nodeCount"
        exit 1
    }

    $env:AZ_BATCH_HOST_LIST.Split(",") | ForEach {
        "$_ 1 $port" | Out-File -Append $vraydr_file
        "$_ 1 $port" | Out-File -Append $vrayrtdr_file
    }

    # Create vray_dr.cfg with cluster hosts
@"
restart_slaves 0
list_in_scene 0
max_servers 0
use_local_machine 0
transfer_missing_assets 1
use_cached_assets 1
cache_limit_type 2
cache_limit 100.000000
"@ | Out-File -Append $vraydr_file

@"
autostart_local_slave 0
"@ | Out-File -Append $vrayrtdr_file

    New-Item "$env:LOCALAPPDATA\Autodesk\3dsMaxIO\2018 - 64bit\ENU\en-US\plugcfg" -ItemType Directory
    cp $vraydr_file "$env:LOCALAPPDATA\Autodesk\3dsMaxIO\2018 - 64bit\ENU\en-US\plugcfg\vray_dr.cfg"
    cp $vrayrtdr_file "$env:LOCALAPPDATA\Autodesk\3dsMaxIO\2018 - 64bit\ENU\en-US\plugcfg\vrayrt_dr.cfg"

# Create preRender script to enable distributed rendering in the scene
@"
-- Enables VRay DR
-- The VRay RT and VRay Advanced renderer have different DR properties
-- so we need to detect the renderer and use the appropriate one.
r = renderers.current
rendererName = r as string
index = findString rendererName "V_Ray_"
if index != 1 then (print "VRay renderer not used, please save the scene with a VRay renderer selected.")
index = findString rendererName "V_Ray_RT_"
if index == 1 then (r.distributed_rendering = true) else (r.system_distributedRender = true;r.system_vrayLog_level = 4; r.system_vrayLog_file = "%AZ_BATCH_TASK_WORKING_DIR%\VRayLog.txt")
"@ | Out-File -Append $pre_render_script
}

# Create pre-render script
$pre_render_script = "prerender.ms"
@"
-- Pre render script
r = renderers.current
"@ | Out-File $pre_render_script

if ($dr)
{
    SetupDistributedRendering
}

if ($irradianceMap)
{
    $irMap = "$env:AZ_BATCH_JOB_PREP_WORKING_DIR\assets\$irradianceMap"
    Write-Error "Setting IR map to $irMap"
@"
-- Set the IR path
r.adv_irradmap_loadFileName = "$irMap"
"@ | Out-File -Append $pre_render_script
}

if ($renderer -eq "arnold")
{
@"
-- Fail on arnold license error
r.abort_on_license_fail = true
"@ | Out-File -Append $pre_render_script
}

$pathFileParam = ""
if ($pathFile)
{
    # If we're using a path file we need to ensure the scene file is located at the same
    # location otherwise 3ds Max 2018 IO has issues finding textures.
    $sceneFileName = [System.IO.Path]::GetFileName($sceneFile)
    $sceneFileDirectory = [System.IO.Path]::GetDirectoryName("$sceneFile")
    $pathFileDirectory = [System.IO.Path]::GetDirectoryName($pathFile)
    if ($sceneFileDirectory -ne $pathFileDirectory)
    {
        Copy-Item -Force "$sceneFile" "$pathFileDirectory" -ErrorAction Stop > $null
        $sceneFile = "$pathFileDirectory\$sceneFileName"
    }
    $pathFileParam = "-pathFile:$pathFile"
}

# Create folder for outputs
mkdir -Force images > $null

# Render
3dsmaxcmdio.exe -secure off -v:5 -rfw:0 -preRenderScript:$pre_render_script -start:$start -end:$end -outputName:"$outputName" -width:$width -height:$height $pathFileParam "$sceneFile"
$result = $lastexitcode

Copy-Item "$env:LOCALAPPDATA\Autodesk\3dsMaxIO\2018 - 64bit\ENU\Network\Max.log" . -ErrorAction SilentlyContinue

exit $result