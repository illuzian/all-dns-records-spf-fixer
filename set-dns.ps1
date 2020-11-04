# Resource groups with target domains
$TargetRG = 'your-resource-grup'
# The SPF record to set
$SPFRecordContents = "v=spf1 include:your-spf.com -all"

$Timestamp = Get-Date -UFormat '%Y%M%d-%H%M%S'

$LogFile = ".\SPFUpdate-$Timestamp.log"

# If set to $true this will action on the zone specified in $SingleTargetZone otherwise it will enumerate all records in the resource group.
$SingleZone = $true
$SingleTargetZone = 'yourzone.com'

# Logging function
function OutputStatus {
    param (
        $Message,
        $LogFile
    )
    $LogTime = Get-Date -UFormat '%Y-%M-%d %H:%M:%S'
    Write-Output $Message
    $LogMessage = "$LogTime $Message"
    Out-File -Append -FilePath $LogFile -InputObject $LogMessage
    
}


function ConfigureSPF {
    param (
        $TargetResourceGroup,
        $TargetZoneName,
        $SPFRecord,
        $LogFile
    )
    
    # Get zone records
    $Records = Get-AzDnsRecordSet -ZoneName $TargetZoneName -ResourceGroupName $TargetResourceGroup
    # CNAME + A
    $CNAMEAndA = $Records | Where-Object { ($_.RecordType -eq 'A' -or $_.RecordType -eq 'CNAME') -and ( $_.Name -notmatch '^\*\.' -and $_.Name -ne '*' -and $_.Name -ne '@')}
    # Existing TXT records
    $TextRecords = $Records | Where-Object { $_.RecordType -eq 'TXT' }
    # All A record subdomains
    $SubDomains = $Records | Where-Object { $_.RecordType -eq 'A' } 
    # All CNAME record subdomains
    $CNAMERecords = $Records | Where-Object { $_.RecordType -eq 'CNAME' } 
    $Root = $Records | Where-Object { $_.Name -eq '@' }
    $SubdomainsWithExistingTXT = @()
  
    $RootSafe = $true
    if ('A' -notin $Root.RecordType -and 'TXT' -notin $Root.RecordType) {
        $Records = @()
        $Records += New-AzDnsRecordConfig -Value $SPFRecord
        New-AzDnsRecordSet -ZoneName $TargetZoneName -Name '@' -RecordType TXT -ResourceGroupName $TargetResourceGroup -TTL 3600 -DnsRecords $Records
        
    } elseif ('A' -notin $Root.RecordType -and 'TXT' -in $Root.RecordType) {
            foreach ($TXTRecord in $Root.Records) {
                if ($TXTRecord -ilike '*v=spf1*') {
                    OutputStatus -LogFile $LogFile -Message  "WARNING: Adding @ as unsafe as it already has an SPF record."
                    $RootSafe = $false
                } 
            }
            if ($RootSafe) {
                OutputStatus -LogFile $LogFile -Message "INFO: @ already has a TXT record. Adding SPF record to existing TXT entries."
                # Get TXT record
                $RootTXTRecord = Get-AzDnsRecordSet -ZoneName $TargetZoneName -RecordType TXT -ResourceGroupName $TargetResourceGroup -Name '@'
                # Append SPF entry to TXT record
                $RootTXTRecord.Records += New-AzDnsRecordConfig -Value $SPFRecord
                # Save the record to Azure
                Set-AzDnsRecordSet -RecordSet $RootTXTRecord -Overwrite

            }
        

    } 
    

    # Check if there were CNAME records and save them
    if ($CNAMERecords.Count -gt 0) {
        OutputStatus -LogFile $LogFile -Message 'WARNING: There were CNAME records detected. SPF must be applied to the referenced domain. Records exported to .\cnames.csv' 
        Export-CSV -Path .\cnames.csv -InputObject $CNAMERecords

    }



    # Store a list of TXT records with existing SPF entries
    $UnsafeTXTRecords = @()
    foreach ($TextRecordSubdomain in $TextRecords) {
        foreach ($TXTRecord in $TextRecordSubdomain.Records) {
            if ($TXTRecord -ilike '*v=spf1*') {
                OutputStatus -LogFile $LogFile -Message  "WARNING: Adding $($TextRecordSubdomain.Name) as unsafe as it already has an SPF record."
                $UnsafeTXTRecords += $TextRecordSubdomain
            }
        }
    }

    # If no valid targets are found
    if ($SubDomains.Count -eq 0) {
        if ($RootSafe) {
            OutputStatus -LogFile $LogFile -Message "INFO: No valid subdomain targets in $TargetZoneName but root was updated"

        } else {
            OutputStatus -LogFile $LogFile -Message "INFO: No valid targets in $TargetZoneName"
        }
        
    }
    # Iterate through the subdomains
    foreach ($SubDomain in $SubDomains) {

        # If there are no TXT records for the given subdomain create an entry
        if ($SubDomain.Name -notin $TextRecords.Name) {
            OutputStatus -LogFile $LogFile -Message "INFO: Adding SPF record to $($SubDomain.Name)"
            # Assemble records array and set on the target subdomain
            $Records = @()
            $Records += New-AzDnsRecordConfig -Value $SPFRecord
            New-AzDnsRecordSet -ZoneName $TargetZoneName -Name $SubDomain.Name -RecordType TXT -ResourceGroupName $TargetResourceGroup -TTL 3600 -DnsRecords $Records
        }

        # If there is an existing TXT record but it has no SPF
        elseif ($Subdomain.Name -notin $UnsafeTXTRecords.Name -and $SubDomain.Name -in $TextRecords.Name) {
            OutputStatus -LogFile $LogFile -Message "INFO: $($SubDomain.Name) already has a TXT record. Adding SPF record to existing TXT entries."
            # Get TXT record
            $SubdomainTXTRecord = Get-AzDnsRecordSet -ZoneName $TargetZoneName -RecordType TXT -ResourceGroupName $TargetResourceGroup -Name $SubDomain.Name
            # Append SPF entry to TXT record
            $SubdomainTXTRecord.Records += New-AzDnsRecordConfig -Value $SPFRecord
            # Save the record to Azure
            Set-AzDnsRecordSet -RecordSet $SubdomainTXTRecord -Overwrite
            
        }

        # If there is already an SPF record
        else {
            OutputStatus -LogFile $LogFile -Message "INFO: $($SubDomain.Name) already has an SPF record."
            $SubdomainsWithExistingTXT += $SubDomain
        }
    }

    # Add wildcards if they don't exist
    foreach ($SubDomain in $CNAMEAndA) {
        $WildcardName = "*.$($SubDomain.Name)"
        if ($WildcardName -notin $TextRecords.Name) {
            
            OutputStatus -LogFile $LogFile -Message "INFO: Adding SPF for *.$($SubDomain.Name)"
            
            $Records = @()
            $Records += New-AzDnsRecordConfig -Value $SPFRecord
            $SubdomainTXTRecord =  New-AzDnsRecordSet -ZoneName $TargetZoneName -Name $WildcardName -RecordType TXT -ResourceGroupName $TargetResourceGroup -TTL 3600 -DnsRecords $Records
            Set-AzDnsRecordSet -RecordSet $SubdomainTXTRecord

            
        } elseif ($WildcardName -in $TextRecords.Name) {
            $SelectedRecord = $TextRecords | Where-Object {$_.Name -eq $WildcardName}


            $DoUpdate = $true
            foreach ($TXTRecord in $SelectedRecord.Records) {
                if ($TXTRecord -ilike '*v=spf1*') {
                    OutputStatus -LogFile $LogFile -Message "INFO: $WildcardName already has an SPF record"
                    $DoUpdate = $false
                }
            }

            if ($DoUpdate) {
                OutputStatus -LogFile $LogFile -Message "INFO: Adding new TXT record with SPF for $WildcardName"
                $SubdomainTXTRecord = Get-AzDnsRecordSet -ZoneName $TargetZoneName -RecordType TXT -ResourceGroupName $TargetResourceGroup -Name $SelectedRecord.Name
                # Append SPF entry to TXT record
                $SubdomainTXTRecord.Records += New-AzDnsRecordConfig -Value $SPFRecord
                # Save the record to Azure
                Set-AzDnsRecordSet -RecordSet $SubdomainTXTRecord -Overwrite
            }
        }
    }
 


}


# Backup existing zones in case something goes wrong.
function BackupDNSObjects {
    param(
        $ZonesToBackup,
        $TargetResourceGroup
    )
    $ZonesBackupPath = ".\ZonesBackup-$Timestamp.clixml"
    OutputStatus -LogFile $LogFile -Message "INFO: Backing up zones object to $ZonesBackupPath"
    $ZonesToBackup | Export-Clixml -Path $ZonesBackupPath -Depth 100
    foreach ($Zone in $ZonesToBackup) {
        $RecordsBackupPath = ".\$($Zone.Name)-Backup-$Timestamp.clixml"
        OutputStatus -LogFile $LogFile -Message "INFO: Backing up $($Zone.Name) records to $RecordsBackupPath"
        Get-AzDnsRecordSet -ZoneName $Zone.Name -ResourceGroupName $TargetResourceGroup | Export-Clixml -Path $RecordsBackupPath -Depth 100
    }

}

# Check single or all zone target
if ($SingleZone) {
    $Zones = Get-AzDnsZone -ResourceGroupName $TargetRG -Name $SingleTargetZone
} else {
    $Zones = Get-AzDnsZone -ResourceGroupName $TargetRG
}

# Call backup function
BackupDNSObjects -ZonesToBackup $Zones -TargetResourceGroup $TargetRG

foreach ($Zone in $Zones) {
    # Skip reverse zones
    if ($Zone.Name -ilike '*in-addr.arpa*') {
        OutputStatus -LogFile $LogFile -Message "INFO: $($Zone.Name) is reverse zone, skipping."
    } 
    
    # Process all other zones
    else {
        OutputStatus -LogFile $LogFile -Message "INFO: Triggering check and update for zone $($Zone.Name)"
        ConfigureSPF -TargetZoneName $Zone.Name -TargetResourceGroup $TargetRG -SPFRecord $SPFRecordContents -LogFile $LogFile
    }
}
