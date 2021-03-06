<#
	.SYNOPSIS
		Script to determine Symantec Endpoint Protection Agent Status on all machines in specified OUs
	.DESCRIPTION
		 Script to poll AD for all computers in a given target OU, then poll each said system to determine if fit is online, gather basic statistics, 
	.PARAM HideConnectionErrors
		Tidy up the output lines by hiding those clients we get RPC errors to. True by default. (Excel mode only)
	.PARAM HideKnownGood
		As the report generates, hide systems not flagged as bad. (Excel mode only)
	.PARAM ShowConnectionErrorsAtEndonly
		Still show connection errors at the end of each list (Excel mode only)
	.PARAM ExcelVisible
		If True will show Excel while generatoring, otherwise it will be hidden
	.PARAM ObjectsOnly
		No Excel mode, will return objects only; useful to integrate into other scripts ($Objects=.\SepStat.ps1)
	.PARAM OutputJSON
		If True will output JSON objects to c:\ representing each scanned object
	.PARAM ExtendedEventLogDebugging
		Perform Extended Event Log Debugging if record is a "problem" record
		Record event log data matching Symantec Endpoint Protection - useful but does at least double the overall run-time and not recommended in Excel mode.
	.PARAM EmailEnabled
		Send Excel report by e-mail at completion; set EmailTo EmailFrom EmailSMTP EmailSubject parameters as well.
	.EXAMPLE
		.\SEPStat.ps1
		For a daily scheduled task, create a .bat with: powershell.exe -ExecutionPolicy Bypass -NoLogo -NoProfile  -Command "\\contoso.com\scripts\powershell\SEPStat\SEPStat.ps1 -EmailEnabled $true"
	.Notes
		.Author 
		Dane Kantner 9/6/13 dane.kantner@gmail.com
			Script dependencies: Unless $OBjectsOnly set to true, Excel 2013 or 2010 required on system running script, Excel 2007 should also work but is untested, AD PowerShell module.
			6/20/2014- Converted output to objects / added parameters for objects only, hiding connection errors, show only known bad
			Fixed SEP12 robustness issues, not dependent upon install location
			7/15/2014 - SEP 12 definition date lookup, Multi-threading added
			8/21/2014 - Added SEP11 def date lookup,  fixed issue with 64->32 system def date on 12 lookup not showing
			9/23/2014 - Added auto e-mail (for easy daily uploading to SharePoint); greatly improved memory/resource utilization on OUs with 1000s of machines
			10/25/2014 - Added JSON output option to save JSON files representing each object, output to c:\ (hard coded, change location if needed; also can change to XML by uncommenting in script)
			2/4/2015 - Removed ActiveDirectory module as dependency, converted script to use ADSISearcher instead. Script can now run with zero dependencies.
#>


[cmdletbinding()]
Param(
	#Tidy up the lines by hiding those clients we get RPC errors to. True by default. (Excel mode only)
	[Parameter(Mandatory=$false, ValueFromPipeLineByPropertyName=$true,ValueFromPipeLine=$true)]
	[bool]$HideConnectionErrors=$True,
	#As the report generates, hide systems not flagged as bad if set to $True. Better for management reporting.
	#Might be useful to show all for version #s though.
	[Parameter(Mandatory=$false, ValueFromPipeLineByPropertyName=$true,ValueFromPipeLine=$true)]
	[bool]$HideKnownGood=$False,  # Recommended: change this to TRUE once you've validated the baseline to only see systems with issues.
	#But Still show them at the end of each OU list? (Excel mode only)
	[Parameter(Mandatory=$false, ValueFromPipeLineByPropertyName=$true,ValueFromPipeLine=$true)]
	[bool]$ShowConnectionErrorsAtEnd=$True,
	#No Excel mode, will return objects only; useful to integrate into other scripts
	[Parameter(Mandatory=$false, ValueFromPipeLineByPropertyName=$true,ValueFromPipeLine=$true)]
	[bool]$ObjectsOnly=$false,
	#Show or Hide Excel. Hiding recommended except for debugging (Excel mode only)
	[Parameter(Mandatory=$false, ValueFromPipeLineByPropertyName=$true,ValueFromPipeLine=$true)]
	[bool]$ExcelVisible=$True,	# Recommend: change this to FALSE once you've validated the initial setup.
	#Perform Extended Event Log Debugging - record event log data matching Symantec Endpoint Protection - useful but does at least double the overall run-time
	[Parameter(Mandatory=$false, ValueFromPipeLineByPropertyName=$true,ValueFromPipeLine=$true)]
	[bool]$ExtendedEventLogDebugging=$False,	
	#Output JSON objects to C:\ as well as Excel?
	[Parameter(Mandatory=$false, ValueFromPipeLineByPropertyName=$true,ValueFromPipeLine=$true)]
	[bool]$OutputJSON=$false,
	[Parameter(Mandatory=$false, ValueFromPipeLineByPropertyName=$true,ValueFromPipeLine=$true)]
	[bool]$EmailEnabled=$True,	# E-mail the results of this scan at end? 
	#I keep this false to prevent overload of e-mails for manual runs, 
	#and set -EmailEnabled in the batch file that runs powershell.exe calling this script:
	[Parameter(Mandatory=$false, ValueFromPipeLineByPropertyName=$true,ValueFromPipeLine=$true)]
	[string]$EmailSMTP="smtp.contoso.com",	# SMTP Server
	[Parameter(Mandatory=$false, ValueFromPipeLineByPropertyName=$true,ValueFromPipeLine=$true)]
	[string]$EmailTo="infosec@sharepoint.contoso.com",	# E-mail Send to (e.g., SharePoint List receive e-mail)
	[Parameter(Mandatory=$false, ValueFromPipeLineByPropertyName=$true,ValueFromPipeLine=$true)]
	[string]$EmailFrom="dane.kantner@gmail.com",	# E-mail "from"
	[Parameter(Mandatory=$false, ValueFromPipeLineByPropertyName=$true,ValueFromPipeLine=$true)]
	[string]$EmailSubject="SEP Status Reports",	# E-mail Subject 
	#(Tip: In Sharepoint enable a list to receive e-mail and allow subject to create new directory within, all reports will then go to same SharePoint folder daily, etc.)
	#Multi-threading throttle limit
	[Parameter(Mandatory=$false, ValueFromPipeLineByPropertyName=$true,ValueFromPipeLine=$true)]
	[int]$ThreadLimit = 14 #threads 
	)
	
cls
 
$Excelfilename="\\contoso.com\dfsny\puball\SEPStatus\SEPStat" 
#
#Populate all OUs to search into $searchbase array -- be sure to leave off comma on final entry
#Can also be only one OU, or a more general scope such as OU=North America,DC=contoso,DC=com vs OU=Sales,OU=New York,OU=North America,DC=contoso,DC=com:
$searchBase = "OU=Desktops,OU=Sales,OU=New York,OU=North America,DC=contoso,DC=com",
	"OU=Other,OU=Sales,OU=New York,OU=North America,DC=contoso,DC=com",
	"OU=Detroit,OU=North America,DC=contoso,DC=com",
	"OU=General,OU=Chicago,OU=North America,DC=contoso,DC=com",
	"OU=Accounting,OU=Chicago,OU=North America,DC=contoso,DC=com",
	"OU=Sales,OU=Los Angeles,OU=North America,DC=contoso,DC=com",
	"OU=Marketing,OU=Los Angeles,OU=North America,DC=contoso,DC=com"
	
	
## END MANDATORY CONFIGURABLE VARIABLES ABOVE ## (remainder optional)
	
	
#Skip checking machines that haven't updated with AD in -XX Days (-92 is default, most online machines would be 30 or less). 
#Number is reference point from today, so a negative number is needed.
$ExpiredMachineDays=-92

$JobsBufferMax=300 #halt processing every $JobsBufferMax machines to flush buffer for large OUs to prevent excessive memory consumption

#column number to store errors in Excel sheet
$errorcolumn=20
$HighlightColumn="T"  #Last column to highlight, in letter form. 
$LogColumn="P" # location of "log" hyperlink column

#END CONFIGURABLE VARIABLES

$Host.UI.RawUI.WindowTitle = "Scanning: $SearchBase"

$ErrorListArray = @()
$dateparts = Get-Date
$Excelfilename=$Excelfilename + $dateparts.Year + "-" + ("{0:d2}" -f $dateparts.Month) + "-" + ("{0:d2}" -f $dateparts.Day) + "-" + ("{0:d2}" -f $dateparts.Hour)
Write-Host "File will save as $Excelfilename"

#BEGIN FUNCTIONS  -- The actual calls to these functions are at the end.


#$ProbeComputerScriptBlock is called in the runspace instances.  Any output must be sent to out-null or object may not be created as expected.
$ProbeComputerScriptBlock = {
   Param (
      [string]$computername,
	  [string]$OperatingSystem,
	  $PasswordLastSet,
	  $ExtendedEventLogDebugging,
	  $OutputJSON
   )
	# Debugging: Output from runspaces will never go to powershell, write debugging needed to c:\debug.txt to see what's going on if needed, uncomment following line for example:
	# "Computer name is " + $computername + " OS is " + $OperatingSystem + " Pwd set is " + $PasswordLastSet + " event debugging is " + $ExtendedEventLogDebugging + " json output is " + $OutputJSON >> c:\debug.txt

   Function Get-WmiCustom2([string]$computername,[string]$namespace,[string]$class,[int]$timeout=15,[string]$whereclause='') {
	#Function Get-WMICustom2 by MSFT's Daniele Muscetta 
	#This is a modified version to add where clause parameter, optional
	#Original function: http://blogs.msdn.com/b/dmuscett/archive/2009/05/27/get_2d00_wmicustom.aspx
	$ConnectionOptions = new-object System.Management.ConnectionOptions
	$EnumerationOptions = new-object System.Management.EnumerationOptions
	$timeoutseconds = new-timespan -seconds $timeout
	$EnumerationOptions.set_timeout($timeoutseconds)
	$assembledpath = "\\" + $computername + "\" + $namespace
	#write-host $assembledpath -foregroundcolor yellow

	$Scope = new-object System.Management.ManagementScope $assembledpath, $ConnectionOptions
	
	try {
		$Scope.Connect()
	} catch {
		$result="Error Connecting " + $_
		return $Result 
	}

	$querystring = "SELECT * FROM " + $class + " " + $whereclause
	$query = new-object System.Management.ObjectQuery $querystring
	$searcher = new-object System.Management.ManagementObjectSearcher
	$searcher.set_options($EnumerationOptions)
	$searcher.Query = $querystring
	$searcher.Scope = $Scope
	
	trap { $_ } $result = $searcher.get()

	return $result
}

Clear-Variable ErrorMessage,onlinestatus,enabledstatus,windowsonline,SymantecAV,SEPStatus,SepDefDate,SepDefRev,ServiceObj,SymantecMissing,SEPLog,SymantecAVwmi,SNACwmi,SNACVersion,AgentStatus,ServiceObj,ServiceWMIObj,Aver,getthis,VersionAgentLink,PingFail,SuspectPermissions,StaleDNS,OS,IPAddress,RegSubKey,ReverseLookup,FQDN -ErrorAction SilentlyContinue
$ErrorMessage=""
$WindowsAccessError=$False
$KnownGood=$True  #start off assuming it is true
#Test if Windows is online by first pinging it (for speed), then accessing c$ (for accuracy). 
#Pinging alone is not a valid test to see if a system is online, since forward DNS record may exist until DNS scaventing takes place
#A new machine may come online and take the IP of the old, but the old machine's forward A record will be pointing to the new machine's IP still. 
#You'd be actually pinging the new machine, not knowing.

$PingResponse=test-connection $computername -count 1 -quiet
if ($PingResponse) { 
	$path="\\" + $computername + "\c$"
	#we have a valid response back, but now make sure it's actually who we think it is by UNCng to C$. This can fail w/out proper permissions.
  	if (-not (Test-Path $path)) {
		$IPAddress = [System.Net.Dns]::GetHostEntry($computername).AddressList | %{$_.IPAddressToString}
		$ReverseLookup=[System.Net.Dns]::GetHostEntry($IPAddress).HostName
		$FQDN=$ComputerName+ "." + $env:userdnsdomain
		if ($ReverseLookup -notlike $FQDN) {
		Write-Error "$path is inaccessible, stale DNS entry. $ReverseLookup $FQDN $IPAddress"
		$script:servicesheet.Cells.Item($Script:hrow,$errorcolumn) = "* Stale DNS; Forward lookup does not match reverse record. Stale record for $FQDN $ReverseLookup $IPAddress"
		$ErrorMessage+="Stale DNS; Forward lookup does not match reverse record. Stale record for $FQDN $ReverseLookup $IPAddress "
		$WindowsOnline=$False
		$StaleDNS=$True
		$WindowsAccessError=$True
		$KnownGood=$False
		} else {
		$script:servicesheet.Cells.Item($Script:hrow,$errorcolumn) = "* $path is an invalid path, likely path due to security reasons"	
		$ErrorMessage="$path is an invalid path, likely path due to security reasons"
		Write-Error "* $path is an invalid path, likely path due to security reasons."
		#Windows actually IS online but we can't access C$, but we confirmed forward and reverse DNS match after pinging successfully.
    	$WindowsOnline=$True
		$WindowsAccessError=$True
		$SuspectPermissions=$True  #might need to know this later for knowing that C$ is not accessible.
		$KnownGood=$False
		}
	} else {
	  	$WindowsOnline=$True
	} #end if test past fail
	$PingFail=$False
} else {
	$PingFail=$True
	Write-Error "Ping failed. $computername"
	$ErrorMessage+="Ping failed. $computername "
	$WindowsOnline=$False
	$WindowsAccessError=$True
	$KnownGood=$False
}

	#establish scope of these variables
	$SMCVersion=""
	$SNACVersion=""
	$SEPVersion=""
	$SEPLog=""
	$ServiceObj=""
	$ServiceWMIObj=""
	$SNACwmi=""
	$SymantecManagementClientwmi=""
	$RemoteRegistryObj=""
	$SymantecManagementClientserv=""
	$SNACserv=""
	$SymantecAVserv=""
	$SEPDataDir=""
	$ChangeStateBack=$false
	$SubKeyNames = ""
	$regKey=""
	$regSubKey=""
	$subKeys=""
	$prefixforreg = "software\Symantec\"
	$SepDefDate=""
	$SepDefDateString=""
	$SepDefRev=""
	$Type = [Microsoft.Win32.RegistryHive]::LocalMachine
	$SEPDefLocation=""
	$SepDefDate=""
	$SepDefDateString=""
	$SepDefRev=""
	$EV=""
	$EVCount=""
	$EVDesc=""
	$EVTemp=""
	$LastReboot=""
	$CheckEV=$False
	$WindowsAccessError=$false
	$ChangeStateBack=$false
	
	if ($WindowsOnline) {
	
		$ServiceWMIObj=@(get-wmicustom2 -class "win32_service" -namespace "root\cimv2" -whereclause "WHERE name='SNAC' or name='SmcService' or name='SepMasterService' or name='Symantec Antivirus' or name='RemoteRegistry'" -computername $computername –timeout 60 -erroraction stop)
		
		if ($ServiceWMIObj.Count -lt 1) {
					$WindowsAccessError=$True
					$ErrorMessage+="Windows is available but no services returned."
					#Write-Host "Service count is 0"
		} else {
	
		$WindowsAccessError=$False
		
		$SNACwmi=$ServiceWMIObj | where { $_.name -eq 'SNAC'}
		$SymantecAVwmi=$ServiceWMIObj | where { ($_.name -eq ('Symantec Antivirus')) -or ($_.name -eq 'SepMasterService')}
		$SymantecManagementClientwmi=$ServiceWMIObj | where { $_.name -eq 'SMCService'}
		$RemoteRegistryObj =  $ServiceWMIObj | where { $_.name -eq 'RemoteRegistry'}
		
		$SEPPath=$SymantecAVwmi.pathname
		$SepPath = $SepPath.Substring(1,$SepPath.Length-2)
		
		$SNACPath=$SNACwmi.pathname
		$SNACPath = $SNACPath.Substring(1,$SNACPath.Length-2)
		
		$SMCPath=$SymantecManagementClientwmi.pathname
		$SMCPath = $SMCPath.Substring(1,$SMCPath.Length-2)
		
		
    	Try #try to open registry without enabling service first.
         	{
				$regKey = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey($Type, $ComputerName)
                $subKeys = $regKey.GetSubKeyNames()
			} Catch {
				if ($RemoteRegistryObj.State -ne 'Running') {
				$ChangeStateBack=$true
				$RemoteRegistryObj.InvokeMethod("StartService",$null) | Out-Null
				Start-Sleep -m 1800
				#give it a chance to actually start. 1.5 second delay
				$regKey = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey($Type, $ComputerName)
              	$subKeys = $regKey.GetSubKeyNames()
				} else {
					$ChangeStateBack=$false
				}
			}    #End Try/Catch for accessing registry. OK ... we have the registry at this point.
			#we either do or don't have a registry connection at this point. Now check for subkeys and if wow6432 is in use.
			
			if ($subKeys.count -gt 0) { #we have access to the keys.
				if ([IntPtr]::size -eq 8) {
					#running a 64 powershell but we are connecting to remote host and need 32 bit location
					$prefixforreg = "software\Wow6432Node\Symantec\"
					#however, if wow6432 itself doesn't exist on remote host, it is a 32 bit host with no wow64 node
					#to begin w/.. which we will change back after first actual reg check
				} elseif ([IntPtr]::size -eq 4) {
					$prefixforreg = "software\Symantec\"
				}
			
			#SEP Data Dir, retrieve def date
			try {
									if ($SepPath -match "sms.dll") {
									   #sepdatadir
										$key = $prefixforreg + "Symantec Endpoint Protection\InstalledApps"
										$regSubKey = $regKey.OpenSubKey($key)
							   
										#12
										$SEPDataDir=$regSubKey.GetValue("SEPAppDataDir")
										$SEPDefLocation=$SEPDataDir + "\Data\Definitions\VirusDefs\definfo.dat"
										$SEPLog=$SepDataDir + "\Data\Logs\AVMan.log"
										$SEPLog=(($SEPLog) -replace ":", "$")
										#path starts with " add \\ $machinename \ after 
										$SEPLog=$SEPLog.insert(0,('\\' + $computername + '\'))
									} else {
										#sepdatadir version 11 - same as 12 but just Symantec\InstalledApps not Symantec\Symantec Endpoint Protection\InstalledApps
										$key = $prefixforreg + "InstalledApps"
										$regSubKey = $regKey.OpenSubKey($key)
				                       	$SEPDataDir=$regSubKey.GetValue("COHDataDir")
										$SEPDefLocation=$SEPDataDir + "\Definitions\VirusDefs\definfo.dat"
									} #end if 11/12
						} catch {
									# 64 bit host but assume 32 bit system only
									$prefixforreg = "software\Symantec\"
								
									if ($SepPath -match "sms.dll") {
										#12
										$key = $prefixforreg + "Symantec Endpoint Protection\InstalledApps"
										$regSubKey = $regKey.OpenSubKey($Key)
		    							$SEPDataDir=$regSubKey.GetValue("SEPAppDataDir")
										$SEPLog=$SepDataDir + "\Data\Logs\AVMan.log"
										$SEPLog=(($SEPLog) -replace ":", "$")
										#path starts with " add \\ $machinename \ after 
										$SEPLog=$SEPLog.insert(0,('\\' + $computername + '\'))
										$SEPDefLocation=$SEPDataDir + "\Data\Definitions\VirusDefs\definfo.dat"
									} else {
										#11
										$key = $prefixforreg + "InstalledApps"
										$regSubKey = $regKey.OpenSubKey($Key)
										$SEPDataDir=$regSubKey.GetValue("COHDataDir")
										$SEPDefLocation=$SEPDataDir + "\Definitions\VirusDefs\definfo.dat"
									} #end if 11/12
								} #end catch
								
								#translate $SEPDefLocation to its network local
								$SEPDefLocation=(($SEPDefLocation) -replace ":", "$")
								#path starts with " add \\ $machinename \ after 
								$SEPDefLocation=$SEPDefLocation.insert(0,('\\' + $computername + '\'))
								#read above for actual version
								$SepDefDate=(Get-Content $SEPDefLocation -totalcount 2)[1]
			#					 "Got content from $SepDefLocation on $computername $SepDefDate" >> c:\debug.txt
								$SepDefDateString=$SepDefDate.substring(8,12)
								$SepDefRev=[int]$SepDefDate.substring(17,3)
								$SepDefDate=$SepDefDate.substring(12,2) + "/" + $SepDefDate.substring(14,2) + "/" + $SepDefDate.substring(8,4)
			} #end if subkeys > 0; registry initial check					
		
		if ($SepPath -match "rtvscan.exe") {
		#SEP 11 - transform to network location - search for ":" and replace with "$"
		$SEPPath=(($SEPPath) -replace ":", "$")
		#path starts with " add \\ $machinename \ after 
		$SEPPath=$SEPPath.insert(0,('\\' + $computername + '\'))
		$SEPVersion=(gcm $SEPPath).FileVersionInfo.ProductVersion
		$SEPLog =(($SEPPath) -replace "rtvscan.exe", "AVMan.log") 
				
		} elseif ($SepPath -match "sms.dll") {
			#version 12
			$SEPVersion="12"
			$SEPLog=""
			
						if ($subKeys.count -gt 0) { #we have access to the keys.
							#SEPVERSION 12 by registry location.
							$key = $prefixforreg + "Symantec Endpoint Protection\CurrentVersion"
							$regSubKey = $regKey.OpenSubKey($Key)
							$SEPVersion=$regSubKey.GetValue("ProductVersion")
							#smc 12
							$key = $prefixforreg + "Symantec Endpoint Protection\SMC"
							$regSubKey = $regKey.OpenSubKey($Key)
	                        #$SubKeyNames = $regSubKey.GetSubKeyNames()
							$SMCVersion=$regSubKey.GetValue("ProductVersion")
							$SMCLocation=$regSubKey.GetValue("smc_install_path")
							$SMCPath=$SMCLocation + "SmcImpl.dll"  #smc.exe is in bin64 but registry doesn't refer to that anywhere only 32 bit, smcimpl.dll is in bin
						} #end if subkeyscount -gt 1
					
		} elseif ($RemoteRegistryObj -ne $null) { #end if sep location is showing it is 12
			#NO SEP Service installed - do we care about the rest?
		
		} #end	if ($SepPath -match "rtvscan.exe") elseif sms.dll 11v12 check

					 
		if ($($SNACPath.length) -gt 0) {
			#transform to network location
			#search for ":" and replace with "$"
			$SNACPath=(($SNACPath) -replace ":", "$")
			#path starts with " add \\ $machinename \ after 
			$SNACPath=$SNACPath.insert(0,('\\' + $computername + '\'))
			$SNACVersion=(gcm $SNACPath).FileVersionInfo.ProductVersion
		}
		
		if ($($SMCPath.length) -gt 0) {
			#transform to network location, search for ":" and replace with "$"
			$SMCPath=(($SMCPath) -replace ":", "$")
			#path starts with " add \\ $machinename \ after 
			$SMCPath=$SMCPath.insert(0,('\\' + $computername + '\'))
			$SMCVersion=(gcm $SMCPath).FileVersionInfo.ProductVersion
			#sep missing, try to infer avman log 
			if ($($SEPLog.length) -lt 2) {
				$SEPLog=(($SMCPath) -replace "Smc.exe", "AVMan.log")  #assumption at this point
				$SEPLog=(($SMCPath) -replace "SmcImpl.dll", "AVMan.log")  #assumption at this point
			}
		}
		
		
		$LastRebootWMIObj=@(get-wmicustom2 -class "Win32_OperatingSystem" -namespace "root\cimv2" -computername $computername –timeout 35 -erroraction stop)
		
		if ($LastRebootWMIObj.Count -gt 0 ) {
			$LastReboot=$LastRebootWMIObj.ConvertToDateTime($LastRebootWMIObj.LastBootUpTime)
		} 
		}
	} #end if windowsonline

		$StatusObject = New-Object psobject
		$StatusObject | Add-Member NoteProperty -Name "ComputerName" -Value $ComputerName
		$StatusObject | Add-Member NoteProperty -Name "WindowsOnline" -Value $WindowsOnline
		$StatusObject | Add-Member NoteProperty -Name "WindowsAccessError" -Value $WindowsAccessError
		$StatusObject | Add-Member NoteProperty -Name "Passwordlastset" -Value $PasswordLastSet
		$StatusObject | Add-Member NoteProperty -Name "OperatingSystem" -Value $OperatingSystem
		
		if ($LastReboot) {
			$StatusObject | Add-Member NoteProperty -Name "LastReboot" -Value $LastReboot
		}
		
		if ($ErrorMessage -ne '') {
			$StatusObject | Add-Member NoteProperty -Name "ErrorMessageThrown" -Value $true
			$StatusObject | Add-Member NoteProperty -Name "ErrorMessage" -Value $ErrorMessage
		} else {
		
			# retrieve service object if any of the services were not found in the original query 
			if ((([string]$SymantecAVwmi.State -eq '') -or ($SymantecAVwmi.State -eq $null) -or ([string]$SymantecManagementClientwmi.State -eq '') -or ($SymantecManagementClientwmi.State -eq $null) -or ([string]$SNACwmi.State -eq '') -or ($SNACwmi.State -eq $null)) -and (-not $WindowsAccessError)) {
				$TestServiceObj=get-service "*" -computername $computername
				$SNACserv=$TestServiceObj | where { $_.name -eq 'SNAC'}
				$SymantecAVserv=$TestServiceObj | where { ($_.name -eq ('Symantec Antivirus')) -or ($_.name -eq 'SepMasterService')}
				$SymantecManagementClientserv=$TestServiceObj | where { $_.name -eq 'SMCService'}
				}
			
			if ((([string]$SymantecAVwmi.State -eq '') -or ($SymantecAVwmi.State -eq $null))  -and (-not $WindowsAccessError)) {
				if ($SymantecAVserv.name) {
					$StatusObject | Add-Member NoteProperty -Name "SymantecAVState" -Value $SymantecAVserv.Status
				} else { # SEP IS MISSING.
					$StatusObject | Add-Member NoteProperty -Name "SymantecAVState" -Value "Missing"
				}
			} else {
				$StatusObject | Add-Member NoteProperty -Name "SymantecAVState" -Value $SymantecAVwmi.State
				$StatusObject | Add-Member NoteProperty -Name "SymantecAVStartMode" -Value $SymantecAVwmi.StartMode
				$StatusObject | Add-Member NoteProperty -Name "SEPPath" -Value $SepPath
				$StatusObject | Add-Member NoteProperty -Name "SEPVersion" -Value $SEPVersion
				$StatusObject | Add-Member NoteProperty -Name "SEPLog" -Value $SEPLog
			}
			if ($SepDefDate -ne '') {
					$StatusObject | Add-Member NoteProperty -Name "SepDefDate" -Value $SepDefDate
					$StatusObject | Add-Member NoteProperty -Name "SepDefRevision" -Value $SepDefRev
			}
			
			
			if ((([string]$SymantecManagementClientwmi.State -eq '') -or ($SymantecManagementClientwmi.State -eq $null)) -and (-not $WindowsAccessError)) {
					if ($SymantecManagementClientserv.name) {
						$StatusObject | Add-Member NoteProperty -Name "SymantecSMCState" -Value $SymantecManagementClientserv.Status
					
					} else { #SMC Not found by way of either probe, SMC is missing
						$StatusObject | Add-Member NoteProperty -Name "SymantecSMCState" -Value "Missing"
					}
			} else {
				$StatusObject | Add-Member NoteProperty -Name "SymantecSMCState" -Value $SymantecManagementClientwmi.State
				$StatusObject | Add-Member NoteProperty -Name "SymantecSMCStartMode" -Value $SymantecManagementClientwmi.StartMode
				$StatusObject | Add-Member NoteProperty -Name "SMCPath" -Value $SMCPath
				$StatusObject | Add-Member NoteProperty -Name "SMCVersion" -Value $SMCVersion
			}
			
			if ((([string]$SNACwmi.State -eq '') -or ($SNACwmi.State -eq $null)) -and (-not $WindowsAccessError)) {
					if ($SNACserv.name) {
						$StatusObject | Add-Member NoteProperty -Name "SNACState" -Value $SNACserv.Status
					
					} else { #SNAC Not installed
						$StatusObject | Add-Member NoteProperty -Name "SNACState" -Value "Missing"
						#Flip KnownGood Here If Desired, ignoring now (not highlighting)
					}
				
			} else {
				$StatusObject | Add-Member NoteProperty -Name "SNACState" -Value $SNACwmi.State
				$StatusObject | Add-Member NoteProperty -Name "SNACStartMode" -Value $SNACwmi.StartMode
				$StatusObject | Add-Member NoteProperty -Name "SNACPath" -Value $SNACPath
				$StatusObject | Add-Member NoteProperty -Name "SNACVersion" -Value $SNACVersion
				}
			}
		#account for statuses being stopped/missing
		if (($StatusObject.SymantecSMCState -ne 'Running') -or ($StatusObject.SymantecAVState -ne 'Running')) {
			$CheckEV=$true   #check extended attributes - this system has issues.  $ExtendedEventLogDebugging must be set
			$StatusObject | Add-Member NoteProperty -Name "KnownGood" -Value $False
		} else {
			$StatusObject | Add-Member NoteProperty -Name "KnownGood" -Value $KnownGood
		}
		
		if (( $SEPVersion -ne '12.1.4112.4156') -and (-not $WindowsAccessError) ) { $CheckEV=$true }
		 #check extended attributes - this system has issues.  $ExtendedEventLogDebugging must be set
		
		#$StatusObject | Add-Member NoteProperty -Name "CheckEV" -Value $CheckEV
		#$StatusObject | Add-Member NoteProperty -Name "ExtendedEventLogDebugging" -Value $ExtendedEventLogDebugging
		
		
		if (($CheckEV) -and (-not $WindowsAccessError) -and ($WindowsOnline) -and ($ExtendedEventLogDebugging)) {
		    #$ExtendedEventLogDebugging is set to true
			#FurtherDebugging is enabled - poll the event log of count items matching *Symantec* and add to object. And then for each unique ID type, pull the most recent description of actual error
			#This significantly slows down the overall search due to retrieving event logs for system over network
			#REMOTE REGISTRY MUST BE STARTED FOR THIS TO WORK.
			$EVCount=""
			$EVDesc=""
			$Last30days=(get-date).adddays(-30)
			$EV=@(get-eventlog -logname System -EntryType Warning,Error -After $Last30days -Computername $ComputerName -Message "*Symantec Endpoint Protection*")
			$EVTemp=@($EV | group-object eventID)
			
			foreach ($Instance in $EVTemp) {
				$EVCount=$EVCount+ "ID " + $Instance.Name + ", " + $Instance.count + " events; "
				#For Each Event ID Type, add the last description from it to a variable
				foreach ($EVItem in $EV) {
					#Find first (newest) description of event message that matches this ID type, then skip out of for loop on to next unique ID type
					if ($EVItem.EventID -eq $Instance.Name) {
						$EVDesc=$EVDesc+"ID " + $($Instance.Name) + " - " + $($EVItem.Message) + " - " + $($EVItem.TimeWritten) + " `n"
						break;
					}
				}
			}
			$StatusObject | Add-Member NoteProperty -Name "EventLogCount" -Value $EVCount
			$StatusObject | Add-Member NoteProperty -Name "EventLogDescription" -Value $EVDesc
	}
	#Get CurrentUser even without extended debugging on.
	if (($CheckEV) -and (-not $WindowsAccessError) -and ($WindowsOnline) ) {
		
			$processinfo=@(get-wmicustom2 -class "win32_process" -namespace "root\cimv2" -whereclause "WHERE ExecutablePath like '%explorer.exe'" -computername $computername –timeout 30 -erroraction stop)
			$UID=''
			if ($processinfo) {    
					$uniqueids=1
	                $processinfo | Foreach-Object {$_.GetOwner().User} | 
	                Where-Object {$_ -ne "NETWORK SERVICE" -and $_ -ne "LOCAL SERVICE" -and $_ -ne "SYSTEM"} |
	                Sort-Object -Unique |
	                ForEach-Object { $UID=$_
						if ($uniqueids -gt 1) { 
							$ObjUID = $ObjUID + ", "  +  $UID
						} else {
							$ObjUID = $UID
							#lookup first user in AD.  
						}
							$uniqueids=1+$uniqueids
					}	#foreach	
					$StatusObject | Add-Member NoteProperty -Name "CurrentUser" -Value $UID
	            }#If processinfo
		}
		
		#All actions on remote system complete; close out the remote registry service that was started, if it wasn't started prior to script running. Leave system like it was.
		if ($ChangeStateBack){
								$RemoteRegistryObj.InvokeMethod("StopService",$null)  | Out-Null
		}
		if ($OutputJSON) {
			$XMLFile="c:\" + $ComputerName + ".xml"
			#$StatusObject  | export-clixml $XMLFile
			$XMLFile=$XMLFile.substring(0,$XMLFile.length-3)+"json"
			try {  Out-File -filePath $XMLFile -encoding ASCII -inputObject (ConvertTo-Json -InputObject $StatusObject)	}
			catch { $Error[0] > $XMLFile }
		}
	return $StatusObject
} #End  ProbeComputerScriptBlock

Function ExcelTranslations($Object) {
$script:servicesheet.Cells.Item($Script:hrow,$Script:hcol) = $Object.ComputerName
$Script:hcol=1+$Script:hcol
$script:servicesheet.Cells.Item($Script:hrow,$Script:hcol) = $Object.WindowsOnline
$Script:hcol=1+$Script:hcol
$script:servicesheet.Cells.Item($Script:hrow,$Script:hcol) = [string]$Object.SymantecAVState
$Script:hcol=1+$Script:hcol
$script:servicesheet.Cells.Item($Script:hrow,$Script:hcol) = [string]$Object.SymantecAVStartMode
$Script:hcol=1+$Script:hcol
$script:servicesheet.Cells.Item($Script:hrow,$Script:hcol) = $Object.SEPVersion
$Script:hcol=1+$Script:hcol
if ($Object.SepDefDate) {
	$script:servicesheet.Cells.Item($Script:hrow,$Script:hcol) = [string]$Object.SepDefDate
}
$Script:hcol=1+$Script:hcol
if ($Object.SepDefRevision) {
	$script:servicesheet.Cells.Item($Script:hrow,$Script:hcol) =  "r" + $Object.SepDefRevision
} 
$Script:hcol=1+$Script:hcol
$script:servicesheet.Cells.Item($Script:hrow,$Script:hcol) = [string]$Object.SymantecSMCState
$Script:hcol=1+$Script:hcol
$script:servicesheet.Cells.Item($Script:hrow,$Script:hcol) = [string]$Object.SymantecSMCStartMode
$Script:hcol=1+$Script:hcol
$script:servicesheet.Cells.Item($Script:hrow,$Script:hcol) = $Object.SMCVersion
$Script:hcol=1+$Script:hcol
$script:servicesheet.Cells.Item($Script:hrow,$Script:hcol) = [string]$Object.SNACState
$Script:hcol=1+$Script:hcol
$script:servicesheet.Cells.Item($Script:hrow,$Script:hcol) = [string]$Object.SNACStartMode
$Script:hcol=1+$Script:hcol
$script:servicesheet.Cells.Item($Script:hrow,$Script:hcol) = $Object.SNACVersion
$Script:hcol=1+$Script:hcol
$script:servicesheet.Cells.Item($Script:hrow,$Script:hcol) = $Object.Passwordlastset
$Script:hcol=1+$Script:hcol
$script:servicesheet.Cells.Item($Script:hrow,$Script:hcol) = $Object.OperatingSystem
$Script:hcol=1+$Script:hcol

if ($Object.SEPLog.Length -gt 0) {
	$script:servicesheet.Cells.Item($Script:hrow,$Script:hcol) = "Log"
	#$myr = $script:servicesheet.Range([string]$HighlightColumn+[string]$Script:hrow+":" + [string]$HighlightColumn +[string]$Script:hrow)
	$myr = $script:servicesheet.Range([string]$LogColumn+[string]$Script:hrow+":" + [string]$LogColumn +[string]$Script:hrow)
	$objLink = $script:servicesheet.Hyperlinks.Add($myr, $Object.SEPLog) 
	while( [System.Runtime.Interopservices.Marshal]::ReleaseComObject($myr)){ }
	while( [System.Runtime.Interopservices.Marshal]::ReleaseComObject($objLink)){ }
}
$Script:hcol=1+$Script:hcol

$script:servicesheet.Cells.Item($Script:hrow,$Script:hcol) = $Object.LastReboot
$Script:hcol=1+$Script:hcol
$script:servicesheet.Cells.Item($Script:hrow,$Script:hcol) = $Object.CurrentUser
$Script:hcol=1+$Script:hcol
$script:servicesheet.Cells.Item($Script:hrow,$Script:hcol) = $Object.EventLogCount
$Script:hcol=1+$Script:hcol
$script:servicesheet.Cells.Item($Script:hrow,$Script:hcol) = $Object.EventLogDescription
$Script:hcol=1+$Script:hcol


if (($Object.WindowsOnline) -and (-not $Object.ErrorMessageThrown)) {
	#HIGHLIGHT IF SMC NOT WORKING; LIGHTER YELLOW
	$SuspectAgent=$False
	If ([string]$Object.SymantecSMCState -eq 'Stopped') {
		$cells = ("A" + [string]$Script:hrow + ":" + $HighlightColumn + [string]$Script:hrow)
		$Range = $script:servicesheet.range("$cells")
		$Range.Interior.ColorIndex=36
		while( [System.Runtime.Interopservices.Marshal]::ReleaseComObject($Range)){ }
		$Script:SMCSuspectAgents=1+$Script:SMCSuspectAgents
		$SuspectAgent=$True
		} elseIf (([string]$Object.SymantecSMCState -ne 'Running')  -and (-not $Object.WindowsAccessError)) {
		$cells = ("A" + [string]$Script:hrow + ":" + $HighlightColumn + [string]$Script:hrow)
		$Range = $script:servicesheet.range("$cells")
		$Range.Interior.ColorIndex=37
		while( [System.Runtime.Interopservices.Marshal]::ReleaseComObject($Range)){ }
		$Script:SMCSuspectAgents2=1+$Script:SMCSuspectAgents2
		$SuspectAgent=$True
	}

	#HIGHLIGHT DARKER NOW IF SEP MISSING
	If (([string]$Object.SymantecAVState -eq 'Stopped') -and (-not $Object.WindowsAccessError)) {
		$cells = ("A" + [string]$Script:hrow + ":" + $HighlightColumn + [string]$Script:hrow)
		$Range = $script:servicesheet.range("$cells")
		$Range.Interior.ColorIndex=46
		while( [System.Runtime.Interopservices.Marshal]::ReleaseComObject($Range)){ }
		$Script:SuspectAgents=1+$Script:SuspectAgents
		$SuspectAgent=$True
	} elseIf (([string]$Object.SymantecAVState -ne 'Running') -and (-not $Object.WindowsAccessError)) {
		$cells = ("A" + [string]$Script:hrow + ":" + $HighlightColumn + [string]$Script:hrow)
		$Range = $script:servicesheet.range("$cells")
		$Range.Interior.ColorIndex=44 
		while( [System.Runtime.Interopservices.Marshal]::ReleaseComObject($Range)){ }
		$Script:SuspectAgents2=1+$Script:SuspectAgents2
		$SuspectAgent=$True
	}
	
	if ($SuspectAgent) {
		$Script:SuspectAgentsTotal=1+$Script:SuspectAgentsTotal
	}
}
	if ($Object.ErrorMessageThrown) {
		$script:servicesheet.Cells.Item($Script:hrow,$errorcolumn)=[string]$Object.ErrorMessage
	} else {
		$Script:TotalOnlineAgents=1+$Script:TotalOnlineAgents
	}

$Script:hcol=1

} #End Function ExcelTranslations



#MAIN FUNCTIONALITY BEGINS HERE.

Clear-Variable SuspectAgents,SuspectAgents2,SuspectAgentsTotal,SMCSuspectAgent2,SMCSuspectAgents,TotalOnlineAgents -ErrorAction SilentlyContinue
$Script:TotalOnlineAgents=0
$Script:SuspectAgents=0
$Script:SuspectAgents2=0
$Script:SMCSuspectAgents=0
$Script:SMCSuspectAgents2=0
$Script:SuspectAgentsTotal=0
$startdate = Get-Date -format G #record when we started this.

if (-not $ObjectsOnly) {
	Write-Host  "Creating Excel Workbook 1"
	# create the Excel application
	$Excel = New-Object -comobject Excel.Application
	# disable Excel alerting (For overwrite of file
	$Excel.DisplayAlerts = $False
	$Excel.Visible = $ExcelVisible
	$workbook = $Excel.Workbooks.Add()
		
	#Column Headings for DS Sheet
	$script:servicesheet = $workbook.sheets.Item(1)
	$headings = @("Name","Windows Online?","SEP Status","SEP Start Mode","SEP Version","Def. Date","Rev","SMC Status","SMC Start Mode","SMC Version","SNAC Status","SNAC Start Mode","SNAC Version","AD Password Date","OS","Log","Last Reboot","Current User","Event Log Errors Last 30 Days","Last Error Description")
	$Script:hrow = 1
	$Script:hcol = 1
	   	 
	$script:servicesheet.Name = "SEP Status"
	$headings | % { 
	   	 $script:servicesheet.cells.item($Script:hrow,$Script:hcol)=$_
	   	 $Script:hcol=1+$Script:hcol
	}

	### Formatting 
	#$script:servicesheet.columns.item("D").Numberformat = "0"
	$script:servicesheet.Rows.Font.Size = 10
	$script:servicesheet.Rows.Item(1).Font.Bold = $true
	$script:servicesheet.Rows.Item(1).Interior.Color = 0xBABABA
	$script:servicesheet.activate()
	$script:servicesheet.Application.ActiveWindow.SplitColumn = 0
	$script:servicesheet.Application.ActiveWindow.SplitRow = 1
	$script:servicesheet.Application.ActiveWindow.FreezePanes = $true
		
	#define Numbers - start all at second row
	$Script:hcol = [Int64]1
	$Script:hrow = [Int64]2

} #end if if (-not $ObjectsOnly) {
	

#get-adcomputer version: $ExpiredDate=(Get-date).AddDays($ExpiredMachineDays)
$ExpiredDate=$((Get-Date).AddDays($ExpiredMachineDays).ToFileTime())

  
foreach ($currentOU in $searchBase) {

$Host.UI.RawUI.WindowTitle = "PowerShell: Scanning " + $currentOU

$strFilter ="(&(objectcategory=Computer)(pwdlastset>=$ExpiredDate)(!OperatingSystem=*mac*))"
$OUString="LDAP://" + $currentOU
Write-Host "Searching $OUstring"
$objOU = New-Object System.DirectoryServices.DirectoryEntry($OUString)
$objSearcher = New-Object System.DirectoryServices.DirectorySearcher
$objSearcher.SearchRoot = $objOU
$objSearcher.SearchScope = "Subtree"
$objSearcher.PageSize = 1000
$objSearcher.PropertiesToLoad.Add("name") | Out-Null
$objSearcher.PropertiesToLoad.Add("pwdlastset") | Out-Null
$objSearcher.PropertiesToLoad.Add("OperatingSystem") | Out-Null
$objSearcher.Filter = $strFilter
$ComputerObjects = $objSearcher.FindAll()


$RunspacePool = [RunspaceFactory]::CreateRunspacePool(1, $ThreadLimit)
$RunspacePool.Open()
$Jobs = @()
$JobNumber=0
$OUCount=0

	for($i=0; $i -lt $computerobjects.count; $i++) {
		$JobNumber=1+$JobNumber
		$OUCount=1+$OUCount
		#convert the ADSI value to string first, then back to date
		$MyPasswdSet=[datetime]::FromFileTime([string]$computerObjects[$i].properties.pwdlastset)
		$Job = [powershell]::Create().AddScript($ProbeComputerScriptBlock).AddArgument(($ComputerObjects[$i].properties.name)).AddArgument(($computerObjects[$i].properties.operatingsystem)).AddArgument($MyPasswdSet).AddArgument($ExtendedEventLogDebugging).AddArgument($OutputJSON)
    	$Job.RunspacePool = $RunspacePool
   		$Jobs += New-Object PSObject -Property @{
   			RunNum = $JobNumber
			Pipe = $Job
			Result = $Job.BeginInvoke()
	  	}
		
		if (($JobNumber%$JobsBufferMax -eq 0) -or ($OUCount -eq $computerobjects.count)) {
		Write-Host "... Flushing Jobs buffer, count: $($Jobs.Count) completing - $OUCount of $($computerobjects.count) .." -NoNewline
		#flush the jobs every $JobsBufferMax or at end of OU when count matches
				 Do {
	  		 Write-Host "." -NoNewline
	  		 Start-Sleep -Seconds 1
			} While ( $Jobs.Result.IsCompleted -contains $false)
			
		ForEach ($Job in $Jobs) {
			$ProbeObject = @($Job.Pipe.EndInvoke($Job.Result))
				
			if (-not $ObjectsOnly) {
				if ($HideConnectionErrors -and (($ProbeObject[0].ErrorMessageThrown) -or ($ProbeObject[0].WindowsAccessError))) {
						
					#we'll just skip this bugger if it was an error.
					$script:servicesheet.Cells.Item($Script:hrow,1) ="" #clear out the first cell that was prepopulated (if applicable)
					$script:servicesheet.Cells.Item($Script:hrow,$errorcolumn) ="" #clear out the error cell that was possibly populated
						if ($ShowConnectionErrorsAtEnd) {
							$ErrorListArray+=$ProbeObject[0]
						}
					#do not increment Excel row
				} else {
					if (($ProbeObject[0].KnownGood) -and ($HideKnownGood)) {
							# skip over it -- it's good but we are hiding these.
						} else {
							ExcelTranslations($ProbeObject[0])
							$Script:hrow=1+$Script:hrow
							#increment Excel row for next run ! ! !
							if (($Script:hrow -eq 15) -or ($Script:hrow -eq 100)){ # a bit into report, size it up for better viewing
								$script:servicesheet.Rows.AutoFit() | Out-Null
								$script:servicesheet.Columns.AutoFit() | Out-Null
						}
					} #end if knowngood/hiding

				} #endif hideconnectionerrors and it was an error.
			} else {
			# Actually return the  object / no Excel
			$ProbeObject[0]
			} #End if not objects only after probe 
		
		} #end foreach job in jobs
		$Jobs = @()
		$JobNumber=0
		} #end if $JobNumber% buffer flush check or end of ADCompObject
	} #end foreach computer in OU loop
	
} #End ForEach Loop for $Ou $Searchbase

#Ending loop, now let's add errors in one swoop to end of list.
if (-not $ObjectsOnly) {
	if ($ErrorListArray.Count -gt 0) {
		foreach ($myitem in $ErrorListArray) {
				ExcelTranslations($Myitem)	
				$Script:hrow=1+$Script:hrow
		} #end foreach loop
	} # if errorlistarray isn't empty

 ### AutoFit Rows and Columns	
$script:servicesheet.Rows.AutoFit() | Out-Null
$script:servicesheet.Columns.AutoFit() | Out-Null
$enddate = Get-Date -format G
$script:hrow = 5+$script:hrow
$script:servicesheet.cells.Item($script:hrow,"A") = "SEP Suspect Clients: $($Script:SuspectAgents+$Script:SuspectAgents2); $Script:SuspectAgents SEP stopped, $Script:SuspectAgents2 SEP missing " 
$script:hrow = 1+$script:hrow
$script:servicesheet.cells.Item($script:hrow,"A") = "SMC Suspect Clients: $($Script:SMCSuspectAgents+$Script:SMCSuspectAgents2); $Script:SMCSuspectAgents SMC stopped, $Script:SMCSuspectAgents2 SMC missing " 
$script:hrow = 1+$script:hrow
$script:servicesheet.cells.Item($script:hrow,"A") = "Total Suspect Clients: $Script:SuspectAgentsTotal (of $Script:TotalOnlineAgents total endpoints successfully probed)." 
$script:hrow = 1+$script:hrow
$script:servicesheet.cells.Item($script:hrow,"A") = "Report Generated: $startdate - $enddate - Running as $env:username " 
Write-Host "`n"

#SAVE Excel File -Note: Excel appends .xlsx file type
	$workbook.SaveAs($Excelfilename)  #an error here about null method is an indication a system is having Excel COM issues and may need a reboot.
	$workbook.Close()
 	$Excel.Quit()
	while( [System.Runtime.Interopservices.Marshal]::ReleaseComObject($script:servicesheet)){ }
	while( [System.Runtime.Interopservices.Marshal]::ReleaseComObject($workbook)){ }
	while( [System.Runtime.Interopservices.Marshal]::ReleaseComObject($Excel)){ }

	$ExcelfilenameFull=$Excelfilename+".xlsx"
	if ($EmailEnabled) {
		Write-Host "E-mailing $Excelfilenamefull to $EmailTo"
		send-mailmessage -from "$EmailFrom" -to "$EmailTo" -subject "$EmailSubject" -Attachments "$ExcelfilenameFull" -smtpServer "$EmailSMTP"
	}
} #end if (-not $ObjectsOnly) 