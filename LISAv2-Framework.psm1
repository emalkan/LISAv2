# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.

using Module "TestControllers\AzureController.psm1"
using Module "TestControllers\HyperVController.psm1"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Get-ChildItem (Join-Path $here "Libraries") -Recurse | Where-Object { $_.FullName.EndsWith(".psm1") } | `
	ForEach-Object { Import-Module $_.FullName -Force -Global -DisableNameChecking }

function Start-LISAv2 {
	[CmdletBinding()]
	Param(
		[string] $ParametersFile = "",

		# [Required]
		[ValidateSet('Azure','HyperV', IgnoreCase = $false)]
		[string] $TestPlatform = "",

		# [Required] for Azure.
		[string] $TestLocation="",
		[string] $ARMImageName = "",
		[string] $StorageAccount="",

		# [Required] for Two Hosts HyperV
		[string] $DestinationOsVHDPath="",

		# [Required] Common for HyperV and Azure.
		[string] $RGIdentifier = "",
		[string] $OsVHD = "",   #... [Azure: Required only if -ARMImageName is not provided.]
								#... [HyperV: Mandatory]
		[string] $TestCategory = "",
		[string] $TestArea = "",
		[string] $TestTag = "",
		[string] $TestNames="",
		[string] $TestPriority="",

		# [Optional] Parameters for Image preparation before running tests.
		[string] $CustomKernel = "",
		[string] $CustomLIS,

		# [Optional] Parameters for changing framework behavior.
		[int]    $TestIterations = 1,
		[string] $TiPSessionId,
		[string] $TiPCluster,
		[string] $XMLSecretFile = "",
		[switch] $EnableTelemetry,
		[switch] $UseExistingRG,

		# [Optional] Parameters for Overriding VM Configuration.
		[string] $CustomParameters = "",
		[string] $OverrideVMSize = "",
		[switch] $EnableAcceleratedNetworking,
		[switch] $ForceDeleteResources,
		[switch] $UseManagedDisks,
		[switch] $DoNotDeleteVMs,
		[switch] $DeployVMPerEachTest,
		[string] $VMGeneration = "",

		[string] $ResultDBTable = "",
		[string] $ResultDBTestTag = "",

		[switch] $ExitWithZero
	)

	PROCESS {
		try {
			# Generate test log file
			$testId = New-TestId
			$logFileName = "LISAv2-Test-${testId}.log"
			Set-Variable -Name "LogFileName" -Value $logFileName -Scope Global -Force
			Set-Variable -Name "TestId" -Value $testId -Scope Global -Force
			Write-LogInfo "Autogenerated test ID: $testId"

			# Prepare the workspace
			$maxDirLength = 32
			$workingDirectory = (Get-Location).Path
			if ($workingDirectory.Length -gt $maxDirLength) {
				$originalWorkingDirectory = $workingDirectory
				$workingDirectory = Move-ToNewWorkingSpace $originalWorkingDirectory | `
					Select-Object -Last 1
			}
			Set-Variable -Name "WorkingDirectory" -Value $workingDirectory -Scope Global

			# Prepare log folder
			$testTimestamp = Get-Date -Format 'yyyy-dd-MM-HH-mm-ss-ffff'
			$logDir = Join-Path $workingDirectory "TestResults\${testTimestamp}"
			New-Item -ItemType "Directory" -Path $logDir -Force | Out-Null
			Write-LogInfo "Logging directory: $logDir"
			Set-Variable -Name "LogDir" -Value $logDir -Scope Global -Force

			# Import parameters from file if ParametersFile parameter is given
			# and set them as global variables
			$paramTable = @{}
			if ($ParametersFile) {
				$paramTable = Import-TestParameters -ParametersFile $ParametersFile
			}
			# Processing parameters provided in the command runtime
			$paramList = (Get-Command -Name $PSCmdlet.MyInvocation.InvocationName).Parameters
			foreach ($paramName in $paramList.Keys) {
				$paramValue = (Get-Variable -Name $paramName -ErrorAction "SilentlyContinue").Value
				if ($paramValue) {
					if ($paramTable.ContainsKey($paramName)) {
						Write-LogInfo "Overwriting parameter $paramName value: $($paramTable[$paramName]) -> $paramValue"
						$paramTable[$paramName] = $paramValue
					} else {
						Write-LogInfo "Setting parameter: $paramName = $paramValue"
						$paramTable.Add($paramName, $paramValue)
					}
				}
			}

			# Validate test platform, and select test controller of the platform
			$supportedPlatforms = @("Azure", "HyperV")
			if ($paramTable.ContainsKey("TestPlatform")) {
				$testPlatform = $paramTable["TestPlatform"]
			}
			if ($testPlatform) {
				if ($supportedPlatforms.contains($testPlatform)) {
					$testController = New-Object -TypeName $testPlatform"Controller"
				} else {
					throw "$testPlatform is not yet supported."
				}
			} else {
				throw "'TestPlatform' parameter is not provided."
			}

			# Validate the test parameters.
			$testController.ParseAndValidateParameters($paramTable)

			# Handle the secrets file
			if ($env:Azure_Secrets_File) {
				$XMLSecretFile = $env:Azure_Secrets_File
				Write-LogInfo "The Secrets file is defined by an environment variable."
			}
			$testController.PrepareTestEnvironment($XMLSecretFile)

			# Validate all the XML files and then import test cases from them for test
			Validate-XmlFiles -ParentFolder $workingDirectory

			$testController.LoadTestCases($workingDirectory, $CustomParameters)

			# Create report folder
			$reportFolder = Join-Path $workingDirectory "Report"
			if (!(Test-Path $reportFolder)) {
				New-Item -ItemType "Directory" $reportFolder | Out-Null
			}
			$TestReportXml = Join-Path "$reportFolder" "LISAv2_TestReport_$testId-junit.xml"

			# Create result folder
			$TestResultsDir = "$WorkingDirectory\TestResults"
			if (!(Test-Path $TestResultsDir)) {
				New-Item -ItemType "Directory" $TestResultsDir | Out-Null
			}

			# Run test
			$testController.RunTest($TestReportXml,$TestIterations,$false)
			Write-LogInfo "Test $global:testId finished"

			# Output text summary
			$plainTextSummary = $testController.TestSummary.GetPlainTextSummary()
			Write-LogInfo $plainTextSummary

			# Zip the test log folder
			$zipFile = "$TestPlatform"
			if ( $TestCategory ) { $zipFile += "-$TestCategory"	}
			if ( $TestArea ) { $zipFile += "-$TestArea" }
			if ( $TestTag ) { $zipFile += "-$($TestTag)" }
			if ( $TestPriority ) { $zipFile += "-$($TestPriority)" }
			$zipFile += "-$testId-TestLogs.zip"
			$zipFile = $zipFile.Replace("*", "All")
			$zipFilePath = Join-Path (Get-Location).Path $zipFile
			New-ZipFile -zipFileName $zipFilePath -sourceDir $LogDir

			if (Test-Path -Path $TestReportXml) {
				Write-LogInfo "Analyzing results.."
				$results = $null
				try {
					$results = [xml](Get-Content $TestReportXml -ErrorAction SilentlyContinue)
				} catch {
					throw "Could not parse test report results"
				}
				$testSuiteresults = $results.testsuites.testsuite
				Write-LogInfo "PASS  : $($testSuiteresults.tests - $testSuiteresults.errors - $testSuiteresults.failures)"
				Write-LogInfo "FAIL  : $($testSuiteresults.failures)"
				Write-LogInfo "ABORT : $($testSuiteresults.errors)"
				if (($testSuiteresults.failures -eq 0) `
							-and ($testSuiteresults.errors -eq 0) `
							-and ($testSuiteresults.tests -gt 0)) {
					$ExitCode = 0
				} else {
					$ExitCode = 1
				}
			} else {
				Write-LogErr "Summary file: $TestReportXml does not exist. Exiting with exit code 1"
				$ExitCode = 1
			}
		} catch {
			$line = $_.InvocationInfo.ScriptLineNumber
			$script_name = ($_.InvocationInfo.ScriptName).Replace($PWD,".")
			$ErrorMessage =  $_.Exception.Message

			Write-LogErr "EXCEPTION: $ErrorMessage"
			Write-LogErr "Source: Line $line in script $script_name."
			$ExitCode = 1
		} finally {
			if ($OriginalWorkingDirectory) {
				Move-BackToOriginalWorkingSpace $WorkingDirectory $OriginalWorkingDirectory $ExitCode
			}
			if ( $ExitWithZero -and ($ExitCode -ne 0) ) {
				Write-LogInfo "Forcefully exiting with exit code 0 as ExitWithZero flag was set to $true"
				$ExitCode = 0
			}
			Write-LogInfo "LISAv2 exit code: $ExitCode"

			Get-Variable -Exclude PWD,*Preference,ExitCode -Scope "Global" | Remove-Variable -Scope "Global" `
				-Force -ErrorAction SilentlyContinue

			if ($ExitCode -ne 0) {
				throw "LISAv2 failed with exit code: $ExitCode"
			}
		}
	}
}

New-Alias -Name Run-LISAv2 -Value Start-LISAv2 -Force

Export-ModuleMember -Function * -Alias *