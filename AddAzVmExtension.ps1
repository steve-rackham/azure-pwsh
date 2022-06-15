
<#
.SYNOPSIS
    Installs one or more VM Agents as extensions for targeted virtual machines.
.DESCRIPTION
    Expected usage for migrated VMs that dont confirm to policy (No image data).
    Agent validate set used to search for whether the extension is already installed.

    Agents:
        MicrosoftMonitoring, known as the MMA agent. Used for Log Analytics and VM insights.
        This agent will be deprecated in August 2024.
        Requires Workspace ID and Key of Log Analytics Workspace for registration. Append these parameters
        if installing this agent.

        AMA, Azure Monitor Agent. This agent supercedes the MMA agent but does not yet have full parity.

        Dependency, Dependency agent for VM Insights and service map.

.NOTES
    Supports Linux and Windows deployments.
.LINK
    NA
.EXAMPLE
    AddAzVMExtension -VMName (Get-AzVM) -Agent AMA, Dependency
    Check and install the AMA extension and the dependency extension on all VMs in the current context if they
    not already associated with the targeted VM.

    For this example, vm-win-aue-01, does not have agents installed.
    vm-win-aue-02, does have the agents installed already.

    Output:

    [ START ] ########################################
    Virtual Machine Extensions: [ Dependency, AMA ]

    [ ACTION ]
    Processing Virtual Machines [ 2 ]...
            [ vm-win-aue-01 ] Dependency Agent...   Installing.
            [ vm-win-aue-02 ] Dependency Agent...   Installed.
            [ vm-win-aue-02 ] AMA Agent...          Installed.
            [ vm-win-aue-01 ] Dependency Agent...   OK
            [ vm-win-aue-01 ] AMA Agent...          Installing.
            [ vm-win-aue-01 ] AMA Agent...          OK

    [ END   ] ########################################

    Action          Processed Errors Duration
    ------          --------- ------ --------
    Dependency, AMA         2      0 00:02:10

#>


function AddAzVMExtension {
    [CmdletBinding(
        SupportsShouldProcess,
        ConfirmImpact = 'High'
    )]
    param (
        [Parameter(
            Mandatory,
            ValueFromPipeline,
            ValueFromPipelineByPropertyName,
            HelpMessage = "Collection of Azure Virtual Machines to be targeted."
        )]
        [Microsoft.Azure.Commands.Compute.Models.PSVirtualMachineList[]]$VMName,

        [Parameter(
            HelpMessage = "Extensions to be applied."
        )]
        [ValidateNotNull()]
        [ValidateSet( "MicrosoftMonitoring", "Dependency", "AMA")]
        [string[]]$Agent,

        [Parameter(
            HelpMessage = "For use with Microsoft Monitoring Agent to register against the workspace."
        )]
        [string]$WorkspaceId,

        [Parameter(
            HelpMessage = "For use with Microsoft Monitoring Agent to register against the workspace."
        )]
        [string]$WorkspaceKey

    )

    begin {
        # Definitions: ############################################################
        # Collection: -------------------------------------------------------------
        $Agent = $Agent | Select-Object -Unique

        Write-Output "[ START ] ########################################"
        Write-Output "Virtual Machine Extensions: [ $($Agent -join ", ") ]"
        $([Char]9)

        [Collections.ArrayList]$Collection = $VMName
        [int]$itemOffset = 0 - ($Collection.Name | Measure-Object -Maximum -Property Length).Maximum
        [int]$AgentOffset = 0 - ($Agent | Measure-Object -Maximum -Property Length).Maximum - 10

        # Counters: ---------------------------------------------------------------
        [int]$CounterTotal = $Collection.Count
        [int]$CounterErrors = 0

        # ACTION: #################################################################
        $StopWatch = [System.Diagnostics.Stopwatch]::new()
        $StopWatch.Start()

        Write-Output "[ ACTION ]"
        Write-Output "Processing Virtual Machines [ $CounterTotal ]..."
    }
    process {
        $Collection | ForEach-Object -Parallel {

            $item = Get-AzVM -ResourceGroupName $_.ResourceGroupName -Name $_.Name
            $OSType = $item.StorageProfile.OsDisk.OsType

            foreach ($i in $using:Agent) {
                if ($item.Extensions.id -Match $i) {
                    Write-Output ("{0}{1, $using:itemOffset} {2, $using:AgentOffset} {3}" -f $([Char]9), "[ $($item.Name) ]", "$i Agent..." , "`tInstalled.")

                } else {
                    switch ($i) {

                        AMA {
                            $AgentParams = @{
                                Name               = "AMA$($OStype)"
                                VMName             = $item.Name
                                Publisher          = "Microsoft.Azure.Monitor"
                                ExtensionType      = "AzureMonitor$($OSType)Agent"
                                Location           = $item.Location
                                ResourceGroupName  = $item.ResourceGroupName
                                TypeHandlerVersion = ($OSType -eq "Windows") ? 1.2 : 1.15
                            }

                            break

                        }

                        MicrosoftMonitoring {

                            $AgentParams = @{
                                VMName             = $item.Name
                                ExtensionName      = "MicrosoftMonitoringAgent"
                                Publisher          = "Microsoft.EnterpriseCloud.Monitoring"
                                ExtensionType      = "MicrosoftMonitoringAgent"
                                Location           = $item.Location
                                ResourceGroupName  = $item.ResourceGroupName
                                TypeHandlerVersion = ($OSType -eq "Windows") ? "1.0" : 1.13
                                Settings           = @{
                                    workspaceId = $WorkspaceId
                                }
                                ProtectedSettings  = @{
                                    workspaceKey = $WorkspaceKey
                                }
                            }

                            break
                        }

                        Dependency {

                            $AgentParams = @{
                                VMName             = $item.Name
                                ExtensionName      = "Microsoft.Azure.Monitoring.DependencyAgent"
                                Publisher          = "Microsoft.Azure.Monitoring.DependencyAgent"
                                ExtensionType      = "DependencyAgent$($OSType)"
                                Location           = $item.Location
                                ResourceGroupName  = $item.ResourceGroupName
                                TypeHandlerVersion = ($OSType -eq "Windows") ? 9.1 : 9.5
                            }

                            break
                        }


                        Default {
                            # ERROR HANDLING:
                            Write-Output ("{0}{1, $using:itemOffset} {2, $using:AgentOffset} {3}" -f $([Char]9), "[ $($item.Name) ]", "$i Agent..." , "`tERROR.")
                            $CounterErrors++
                            Return
                        }
                    }

                    try {
                        Write-Output ("{0}{1, $using:itemOffset} {2, $using:AgentOffset} {3}" -f $([Char]9), "[ $($item.Name) ]", "$i Agent..." , "`tInstalling...")
                        $Result = Set-AzVMExtension @AgentParams -ErrorAction Stop

                    } catch {
                        Write-Output ("{0}{1, $using:itemOffset} {2, $using:AgentOffset} {3}" -f $([Char]9), "[ $($item.Name) ]", "$i Agent..." , "`tERROR.")
                        Write-Output ("{0}{1, $using:itemOffset} {22, $using:AgentOffset}" -f $([Char]9), "[ $($item.Name) ]", "$i Agent..." , $Error[0].ErrorRecord.Messsage)
                    }


                    # OUTPUT: #############################################################
                    Write-Output ("{0}{1, $using:itemOffset} {2, $using:AgentOffset} {3}" -f $([Char]9), "[ $($item.Name) ]", "$i Agent..." , "`t$($Result.StatusCode)")
                }
            }
        }
    }

    end {
        $([Char]13)
        Write-Output "[ END   ] ########################################"
        $OutputObject = [PSCustomObject][Ordered]@{
            Action    = "$($Agent -join ", ")"
            Processed = $CounterTotal
            Errors    = $CounterErrors
            Duration  = "{0:d2}:{1:d2}:{2:d2}" -f $StopWatch.Elapsed.Hours, $StopWatch.Elapsed.Minutes, $StopWatch.Elapsed.Seconds
        }

        Return $OutputObject
        $StopWatch.Stop()
    }
}


