<#
.SYNOPSIS
    Export Network Security Groups for backup.
.DESCRIPTION
    Use Automation Account with associate Managed Identity to export Network Security group.
    Managed Identity is mandatory and user based recommended.
    This is to encourage use of user-based managed itendities with least privilege roles assigned.
    Assign a schedule or webhook as appropriate.
.
.NOTES
    It is expected that the Automation Account is assigned per environment for security purposes.
#>

param (
    [Parameter(
        Mandatory,
        HelpMessage = "Storage Account for the JSON Files."
    )]
    [string]$StorageAccountName,

    [Parameter()]
    [string]$IdentityID = "8af344ab-21dd-45f7-83dc-6f6230d6da28",

    #TODO: Automation Account is not honouring string array. Kept to single for now while diagnosing so can at least
    # configure multiple schedules.
    [Parameter(Mandatory)]
    [ValidateSet("AzFirewall", "AzLoadBalancer", "WAF", "NSG")]
    [string]$ResourceType
)

# CONNECTION: #########################################################
try {
    Write-Output "[ CONNECTION ]"
    Write-Output "Set Connection Context..."
    Write-Output ("{0}{1}" -f $([Char]9), "Disable Autosave Context...")
    [void](Disable-AzContextAutosave -Scope Process)

    Write-Output ("{0}{1}" -f $([Char]9), "Connecting Managed Identity [ $IdentityID ]...")
    $AzureContext = (Connect-AzAccount -Identity -AccountId $IdentityID ).context

    Write-Output ("{0}{1}" -f $([Char]9), "Set and Store Azure Context...")
    $AzureContext = Set-AzContext -SubscriptionName $AzureContext.Subscription -DefaultProfile $AzureContext

} catch {
    Write-Output ("{0}{1}" -f $([Char]9), "ERROR.")
    Write-Output ("{0}{1}" -f $([Char]9), $($Error[0].Exception.Message))
}


# DEFINITIONS: ########################################################
$StopWatch = [System.Diagnostics.Stopwatch]::new()
$StopWatch.Start()
$CounterErrors = 0

$([Char]13)
Write-Output "[ START ] ########################################"
Write-Output "Connected Tenancy:        [ $($AzureContext.Tenant.Id) ]"
Write-Output "Connected Subscription:   [ $($AzureContext.Subscription.Name) ]"


# STORAGE ACCOUNT: ############################################################
try {
    $([Char]13)
    Write-Output "[ STORAGE ACCOUNT ]"
    Write-Output "Checking Storage Account...[ $StorageAccountName ]"
    $StorageAccountName = $StorageAccountName.ToLower()

    $StorageAccount = Get-AzStorageAccount | Where-Object StorageAccountName -EQ $StorageAccountName

} catch {
    Write-Output ("{0}{1} {2}" -f $([Char]9), "[ $StorageAccountName ]", "ERROR.")
    Write-Output ("{0}{1} {2}" -f $([Char]9), "[ $StorageAccountName ]", $($Error[0].Exception.Message))
    $CounterErrors++
    exit
}


foreach ($item in $ResourceType) {
    # Resource Definitions: ---------------------------------------------------
    $CounterTotal = 0
    $item = $item.ToLower()

    # CONTAINERS: #############################################################
    try {
        Write-Output "Checking Storage Account Container...[ $item ]"
        $StorageAccountContainer = $StorageAccount | Get-AzStorageContainer | Where-Object { $_.Name -match $item }

        if ($null -eq $StorageAccountContainer) {
            Write-Output ("{0}{1} {2}" -f $([Char]9), "[ $StorageAccountName ]", "Creating Container for [ $item ]...")
            [void]($StorageAccount | New-AzStorageContainer $item)
        }

    } catch {
        Write-Output ("{0}{1} {2}" -f $([Char]9), "[ $StorageAccountName ]", "ERROR.")
        Write-Output ("{0}{1} {2}" -f $([Char]9), "[ $StorageAccountName  ]", $($Error[0].Exception.Message))
        $CounterErrors++
        break
    }


    switch ($item) {
        AzFirewall {
            $Result = Get-AzFirewall
            break
        }
        AzLoadBalancer {
            $Result = Get-AzLoadBalancer
            break
        }
        WAF {
            $Result = Get-AzApplicationGateway
            break
        }
        NSG {
            $Result = Get-AzNetworkSecurityGroup
            break
        }
        Default {
            Write-Output "Invalid Resource [ $item ] "
            break
        }
    }

    # Validation: #############################################################

    [int]$CounterTotal = $Result.Count
    $([Char]13)
    Write-Output "[ BACKUP ]"
    Write-Output "Backup [ $item ] [ $CounterTotal ]..."

    if ($CounterTotal -eq 0) {
        Write-Output ("{0}{1}" -f $([Char]9), "No Match Found. Break.")
        break
    }

    # Process: ################################################################
    $Result | ForEach-Object -ThrottleLimit 5 -Parallel {
        try {

            $ExportParams = @{
                ResourceGroupName = $PSItem.ResourceGroupName
                Resource          = $PSItem.Id

            }

            Write-Output ("{0}{1} {2}" -f $([Char]9), "[ $($PSItem.Name) ]", "Exporting...")
            $Export = Export-AzResourceGroup @ExportParams -SkipAllParameterization -Force


            if ($Export) {

                $BlobParams = @{
                    Blob      = $($PSItem).Name + ".json"
                    Container = $using:item
                    File      = $Export.Path
                    Context   = $using:StorageAccount.Context
                }

                Write-Output ("{0}{1} {2}" -f $([Char]9), "[ $($PSItem.Name) ]", "Uploading [ $($BlobParams.Blob) ]...")
                [void](Set-AzStorageBlobContent @BlobParams -Force)

                Write-Output ("{0}{1} {2}" -f $([Char]9), "[ $($PSItem.Name) ]", "Uploaded [ $($BlobParams.Blob) ] [ OK ]")

            }

        } catch {
            Write-Output ("{0}{1} {2}" -f $([Char]9), "[ $($PSItem.Name) ]", "ERROR!")
            Write-Output ("{0}{1} {2}" -f $([Char]9), "[ $($PSItem.Name) ]", $($Error[0].Exception.Message))
            $CounterErrors++
        }
    }
}

$([Char]13)
Write-Output "[ END   ] ########################################"
$OutputObject = [PSCustomObject][Ordered]@{
    Resource = $($ResourceType -join ", ")
    Errors   = $CounterErrors
    Duration = "{0:d2}:{1:d2}:{2:d2}" -f $StopWatch.Elapsed.Hours, $StopWatch.Elapsed.Minutes, $StopWatch.Elapsed.Seconds
}

Write-Output $OutputObject
$StopWatch.Stop()
