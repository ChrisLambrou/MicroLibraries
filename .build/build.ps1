# This file cannot be invoked directly; it simply contains a bunch of Invoke-Build tasks. To use it, invoke
# _init.ps1 which declares three global functions (build, clean, rebuild), then invoke one of those functions.

[CmdletBinding()]
param([string]$Configuration = 'Release')

use 14.0 MSBuild

# Useful paths used by multiple tasks.
$RepositoryRoot = "$PsScriptRoot\.." | Resolve-Path
$SourceDir = "$RepositoryRoot\Source" | Resolve-Path
$SolutionPath = "$SourceDir\Redgate.MicroLibraries.sln" | Resolve-Path
$NuGetPath = "$PsScriptRoot\nuget.exe" | Resolve-Path
$DistDir = "$RepositoryRoot\Dist"
$CopyrightHeader = @"
/*
Copyright 2016-$(Get-Date -Format yyyy) Red Gate Software Ltd (https://github.com/red-gate/MicroLibraries)

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
License and this notice. You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an
"AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific
language governing permissions and limitations under the License.

In addition, the copyright holders grant permission to reproduce and distribute copies of this software or derivative
works thereof in any medium, with or without modifications, in Object form (as defined by the License), without
satisfying the requirements of section 4a of the License. In practice, this means that you are free to include this
library in binary releases of your own software without having to also include this notice, a copy of the Licence, or
any other copyright attribution.
*/
"@


# Helper function for clearer logging of each task.
function Write-Info {
    [CmdletBinding()]
    param ([string] $Message)

    Write-Host "## $Message ##" -ForegroundColor Magenta
}


# Environment-specific configuration should happen here (and only here!)
task Init {
    Write-Info 'Establishing build properties'

    $script:IsAutomatedBuild = $env:BRANCH_NAME -and $env:BUILD_NUMBER
    Write-Host "Is automated build = $IsAutomatedBuild"
    
    $script:BranchName = Get-BranchName
    Write-Host "Branch name = $BranchName"
    
    $script:IsDefaultBranch = $BranchName -eq 'master'
    Write-Host "Is default branch = $IsDefaultBranch"
}

function Get-BranchName {
    # If the branch name is specified via an environment variable (i.e. on TeamCity), use it.
    if ($env:BRANCH_NAME) {
        return $env:BRANCH_NAME
    }

    # If the .git folder is present, try to get the current branch using Git.
    $DotGitDirPath = "$RepositoryRoot\.git"
    if (Test-Path $DotGitDirPath) {
        Add-Type -Path ("$PsScriptRoot\packages\GitSharp\lib\GitSharp.dll" | Resolve-Path)
        Add-Type -Path ("$PsScriptRoot\packages\SharpZipLib\lib\20\ICSharpCode.SharpZipLib.dll" | Resolve-Path)
        Add-Type -Path ("$PsScriptRoot\packages\Tamir.SharpSSH\lib\Tamir.SharpSSH.dll" | Resolve-Path)
        Add-Type -Path ("$PsScriptRoot\packages\Winterdom.IO.FileMap\lib\Winterdom.IO.FileMap.dll" | Resolve-Path)
    
        $Repository = New-Object 'GitSharp.Repository' $DotGitDirPath
        return $Repository.CurrentBranch.Name
    }

    # Otherwise, assume 'dev'
    Write-Warning "Unable to determine the current branch name using either git or the BRANCH_NAME environment variable. Defaulting to 'dev'."
    return 'dev'
}


# Clean task, deletes all build output folders.
task Clean {
    Write-Info 'Cleaning build output'

    Get-ChildItem $RepositoryRoot -Exclude @('packages') -Include @('Dist', 'bin', 'obj') -Directory -Recurse | ForEach-Object {
        Write-Host "Deleting $_"
        Remove-Item $_ -Force -Recurse
    }
}


# RestorePackages task, restores all the NuGet packages.
task RestorePackages {
    Write-Info "Restoring NuGet packages for solution $SolutionPath"

    & $NuGetPath @('restore', $SolutionPath)
}


# Compile task, runs MSBuild to build the solution.
task Compile  RestorePackages, {
    Write-Info "Compiling solution $SolutionPath"

    exec {
        msbuild "$SolutionPath" /nodeReuse:False /target:Build /property:Configuration=Release
    }
}


# Test task, runs the automated tests.
task Test  Compile, {
    Write-Info 'Running tests'

    # Loop through each project.
    Get-ChildItem $SourceDir -Directory -Filter 'ULibs.*' | ForEach-Object {
        $ProjectDir = $_.FullName
        $ProjectName = $_.Name
        Write-Host "Project folder found: $ProjectDir"
        
        $TestAssemblyPath = "$ProjectDir\bin\Release\$ProjectName.dll" | Resolve-Path
        Invoke-NUnit3ForAssembly -AssemblyPath $TestAssemblyPath -NUnitVersion '3.6.1' `
                                 -FrameworkVersion 'net-3.5' `
                                 -EnableCodeCoverage $True `
                                 -DotCoverFilters '+:ULibs.*;-:*.Tests' `
                                 -DotCoverAttributeFilters '*.ExcludeFromCodeCoverageAttribute'
                                 
        $CoverageResultsPath = "$TestAssemblyPath.TestResult.coverage.snap" | Resolve-Path
        TeamCity-ImportDotNetCoverageResult 'dotcover' $CoverageResultsPath        
    }
}


# Package task, generates NuGet packages for each micro-library.
task Package {
    Write-Info 'Generating NuGet packages'

    # Create the output folder.
    $Null = mkdir $DistDir -Force

    # Loop through each project.
    Get-ChildItem $SourceDir -Directory -Filter 'ULibs.*' | ForEach-Object {
        $ProjectDir = $_.FullName
        $ProjectName = $_.Name
        Write-Host "Project folder found: $ProjectDir"
        
        $NuSpecPath = "$ProjectDir\$ProjectName.nuspec" | Resolve-Path
        $ReleaseNotesPath = "$ProjectDir\RELEASENOTES.md" | Resolve-Path
        $ReadmePath = "$ProjectDir\README.md" | Resolve-Path
        
        # Locate source files to be included in the package, and generate their corresponding .pp files.
        Get-ChildItem $ProjectDir -Filter *.cs | ForEach-Object {
            $InputPath = $_.FullName
            $OriginalContents = [System.IO.File]::ReadAllText($InputPath, [System.Text.Encoding]::UTF8)
            $ModifiedContents = $OriginalContents.Replace('/***', '').Replace('***/', '')
            if ($OriginalContents -ne $ModifiedContents) {
                Write-Host "  Including file $InputPath"
                
                $ModifiedContents = "$CopyrightHeader`r`n`r`n$ModifiedContents"
                
                $OutputPath = "$InputPath.pp"
                Write-Host "    Rewriting to $OutputPath"
                [System.IO.File]::WriteAllText($OutputPath, $ModifiedContents, [System.Text.Encoding]::UTF8)
            }
        }
        
        # Establish release notes and package version number from the RELEASENOTES.md file.
        $Notes = Read-ReleaseNotes $ReleaseNotesPath -ThreePartVersion
        $ReleaseNotes = $Notes.Content
        $Version = $Notes.Version
        Write-Host "Version from release notes: $Version"
        
        # Establish the description from the README.md file.
        $Description = [System.IO.File]::ReadAllText($ReadmePath, [System.Text.Encoding]::UTF8).Trim()

        # Establish NuGet package version.
        $BranchName = Get-BranchName
        $IsDefaultBranch = $BranchName -eq 'master'
        $NuGetPackageVersion = New-SemanticNuGetPackageVersion -Version $Version -BranchName $BranchName -IsDefaultBranch $IsDefaultBranch
        Write-Host "NuGet package version = $NuGetPackageVersion"
        
        # Run NuGet pack.
        $Parameters = @(
            'pack',
            "$NuSpecPath",
            '-Version', $NuGetPackageVersion,
            '-OutputDirectory', $DistDir,
            '-Properties', "releaseNotes=$ReleaseNotes;description=$Description"
        )
        Write-Host "$NuGetPath $Parameters"
        exec {
            & $NuGetPath $Parameters
        }

        # Delete the temporary .pp files.
        Get-ChildItem $ProjectDir -Filter *.pp | Remove-Item
    }
}



task Build  Test, Package
task Rebuild  Clean, Build
task Default  Build