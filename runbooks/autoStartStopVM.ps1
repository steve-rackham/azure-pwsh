
#Requires -Version 7
<#
.SYNOPSIS
    Start or Stop Azure Virtual Machines based on Tag Name and/or Value.
.DESCRIPTION
    Use Automation Account with associate Managed Identity to start or stop Azure Virtual Machines based on Tag Name and/or Value.
    Managed Identity is mandatory and user based recommended.
    This is to encourage use of user-based managed itendities with least privilege roles assigned.
    Create a custom role and assign appropriate permissions.
    Assign a tag to the desired virtual machines and add this runbook to a schedule with the appropriate parameters.
    The runbook can be associated with as many schedules, webhooks, and tags as required.
.NOTES
    It is expected that the Automation Account is assigned per environment for security purposes.
    For workloads that need to come up in order create a schedule that accounts for the backend to be available.

    Author: Steve Rackham
    Blog: https://siliconwolf.net

.LINK
    Specify a URI to a help page, this will show when Get-Help -Online is used.
.EXAMPLE
    Start tagged virtual machines at 7am.
    Assign Tag: StartAt : 7am
    Associate schedule for recurring event.
    Set parameters:
        TagName: StartAt (note: case insensitive.)
        TagValue: 7am (note: case insensitive.)
        IdentityID: <Managed Identity Client ID>
        Action: Stop (note: case insensitive.)
    Virtual Machines matching the tag name and value will be stopped at the scheduled time.
.EXAMPLE
    Stop all development tagged virtual machines at 7pm.
    Assign Tag: Dev : This VM will stop at 7pm
    Associate schedule for recurring event.
    Set parameters:
        TagName: Dev (note: case insensitive.)
        TagValue: $Null
        IdentityID: <Managed Identity Client ID>
        Action: Stop (note: case insensitive.)
    Virtual Machines matching the tag name 'Dev' will be stopped at the scheduled time.
#>

param (
    [Parameter(
        Mandatory,
        HelpMessage = "Tag Name (Key) associated with the Stop/Stop action. Tags provide flexibility to target as desired."
    )]
    [string]$TagName,

    [Parameter(
        HelpMessage = "Tag Value allows for further granularity."
    )]
    [string]$TagValue,

    [Parameter(
        Mandatory,
        HelpMessage = "The User Managed Identity Client ID with sufficent permissions; recommend a custom role.")]
    [string]$IdentityID,

    [Parameter(
        Mandatory,
        HelpMessage = "Action, will the targeted virtual machines start or stop with the associated Tag and Key/Value?"
    )]
    [ValidateSet("Stop", "Start")]
    [string]$Action
)

# CONNECTION: #########################################################
Write-Output "[ START ] ########################################"
Write-Output "$Action Virtual Machines matching tag [ $TagName : $TagValue]..."
$([Char]13)

Write-Output "[ CONNECTION ]"
Write-Output "Set Connection Context..."
Write-Output ("{0}{1}" -f $([Char]9), "Disable Autosave Context...")
[void](Disable-AzContextAutosave -Scope Process)

Write-Output ("{0}{1}" -f $([Char]9), "Connecting Managed Identity [ $IdentityID ]...")
$AzureContext = (Connect-AzAccount -Identity -AccountId $IdentityID ).context

Write-Output ("{0}{1}" -f $([Char]9), "Connected. Set and Store Azure Context...")
$AzureContext = Set-AzContext -SubscriptionName $AzureContext.Subscription -DefaultProfile $AzureContext

# Definitions: ################################################################
# Collection: -----------------------------------------------------------------
$([Char]13)
Write-Output "[ TAGGED VIRTUAL MACHINES ]"
Write-Output "Searching Virtual Machines for matching tag [ $TagName : $TagValue]..."
$ResourceParams = @{
    TagName     = $TagName
    TagValue    = $TagValue
    ErrorAction = Stop
}
[System.Collections.Generic.List]$Collection =
            (Get-AzResource @ResourceParams).where({ $_.ResourceType -like "Microsoft.Compute/virtualMachines" })

# Counters: -------------------------------------------------------------------
[int]$CounterTotal = $Collection.Count
[int]$CounterErrors = 0

# Validation: #################################################################
if ($CounterTotal -eq 0) {
    Write-Output ("{0}{1}" -f $([Char]9), "No Match Found. Exiting.")
    Return
}

# ACTION: #####################################################################
$([Char]13)
Write-Output "[ ACTION ]"
Write-Output "$Action Virtual Machines [ $CounterTotal ]..."

$StopWatch = [System.Diagnostics.Stopwatch]::new()
$StopWatch.Start()

$Collection | ForEach-Object -Parallel {

    $item = Get-AzVM -ResourceGroupName $_.ResourceGroupName -Name $_.Name -Status
    $Status = ($item.Statuses[1]).DisplayStatus

    switch ($using:Action) {
        Stop {
            switch ($Status) {
                "VM deallocated" {
                    Write-Output ("{0}{1} {2}" -f $([Char]9), "[ $($item.Name) ]", $Status)
                }
                "VM Running" {
                    Write-Output ("{0}{1} {2}" -f $([Char]9), "[ $($item.Name) ]", "Stopping...")
                    $Result = Stop-AzVM -ResourceGroupName $item.ResourceGroupName -Name $item.Name -Force -Confirm:$false
                    Write-Output ("{0}{1} {2}" -f $([Char]9), "[ $($item.Name) ]", $Result.Status)
                    if ($null -ne $Result.Error) {
                        Write-Output ("{0}{1} {2}" -f $([Char]9), "[ $($item.Name) ]", $Result.Error)
                    }
                }
                Default {
                    Write-Output ("{0}{1} {2}" -f $([Char]9), "[ $($item.Name) ]", "Inconsistent State. [ $Status ]")
                    $CounterErrors++
                }
            }
        }
        Start {
            switch ($Status) {
                "VM deallocated" {
                    Write-Output ("{0}{1} {2}" -f $([Char]9), "[ $($item.Name) ]", "Starting...")
                    $Result = Start-AzVM -ResourceGroupName $item.ResourceGroupName -Name $item.Name -Confirm:$false
                    Write-Output ("{0}{1} {2}" -f $([Char]9), "[ $($item.Name) ]", $Result.Status)
                    if ($null -ne $Result.Error) {
                        Write-Output ("{0}{1} {2}" -f $([Char]9), "[ $($item.Name) ]", $Result.Error)
                    }
                }
                "VM Running" {
                    Write-Output ("{0}{1} {2}" -f $([Char]9), "[ $($item.Name) ]", $Status)
                }
                Default {
                    Write-Output ("{0}{1} {2}" -f $([Char]9), "[ $($item.Name) ]", "Inconsistent State. [ $Status ]")
                    $CounterErrors++
                }
            }
        }
        Default {
            Write-Output ("{0}{1} {2}" -f $([Char]9), "[ $($item.Name) ]", "$Action Error.")
            $CounterErrors++
        }
    }
}

$([Char]13)
Write-Output "[ END   ] ########################################"
$OutputObject = [PSCustomObject][Ordered]@{
    Action    = $Action
    Processed = $CounterTotal
    Errors    = $CounterErrors
    Duration  = "{0:d2}:{1:d2}:{2:d2}" -f $StopWatch.Elapsed.Hours, $StopWatch.Elapsed.Minutes, $StopWatch.Elapsed.Seconds
}

Write-Output $OutputObject
$StopWatch.Stop()
