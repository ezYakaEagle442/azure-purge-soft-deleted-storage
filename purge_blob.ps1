
# ====================================================================================
# Azure Storage - Permanent Delete Soft-Deleted objects (Base Blobs, Blob Snapshots, Versions)
# Based on Container, prefix, Tier and considering Last Modified Date
# ====================================================================================
# DISABLE SOFT DELETE FEATURE ON STORAGE ACCOUNT BEFORE RUNNING THIS SCRIPT
# Otherwise the soft delteded snapshots reapers in sof-deleted state
# You can reenable Soft Delete featurs after running this script, if needed.
# ====================================================================================
# DISCLAMER : please note that this script is to be considered as a sample and is provided as is with no warranties express or implied, even more considering this is about deleting data. 
# We really recommended to double check that list of filtered elements looks fine to you before processing with the deletion with the last line of the script.  
# This script should be tested in a dev environment before using in Production.
# You can use or change this script at you own risk.
# ====================================================================================
# PLEASE NOTE :
# - For this to work we must first disable Blob soft-delete feature before run the script. 
#   Please wait 30s after you disabled soft-delete for the effect to propagate. 
#   After script has finished running and cleared all the undesired blobs and versions, you may renable soft-delete if needed.
# - Just run the script and your AAD credentials and the storage account name to list will be asked.
# - All other values should be defined in the script, under 'Parameters - user defined' section.
# ====================================================================================
# SIDE NOTE:
# deletetype (Permanent) option on Bedete Blob Rest API call can be also used to permanent delete soft-deleted objects, but needs permanent delete enabled for the storage account.
# https://learn.microsoft.com/en-us/rest/api/storageservices/delete-blob#permanent-delete
#
# On this script a different approach was used, to avoid having permanent delete enabled for the storage account.
# Instead of that, we first undelete soft-deleted objects, and then use Remove-AzStorageBlob to permanent delete all objects in $listOfDeletedBlobs array
# ====================================================================================
# For any question, please contact Luis Filipe (Msft)
# ====================================================================================
## Version 2.0 ##
# ====================================================================================
# Corrections:
# Final Sum for Total Soft Deleted Objects Count
# Different function with different output for flat namespace and ADLS Gen2 accounts
# ====================================================================================
# Known Limitations - ADLS Gen2:
#---------
#  ADSLS Gen2 supports Soft Delete, No support for versions, Snapshots or Prefix (not coveresd by this script)
#---------
# Message - The specified blob already exists:
#   To permanent delete a file, it needs first be undeleted. Having an active file with same name, the deleted one cannot be undeleted.
#   If that ocurrs, the script stops and no other files will be processed
#---------
#  List Blobs, Undelete blobs & Permanet delete (need soft Delete Disabled at storage level)
#---------
# Known Limitation - Flat Namespace:
#---------
# Requires action Microsoft.Storage/storageAccounts/blobServices/containers/blobs/deleteBlobVersion/action
# or Storage Blob Data Owner RBAC role
#----------------------------------------------------------------------

Connect-AzAccount 
CLS

#----------------------------------------------------------------------
# Parameters - user defined
#----------------------------------------------------------------------
$selectedStorage = Get-AzStorageAccount  | Out-GridView -Title 'Select your Storage Account' -PassThru  -ErrorAction Stop
$storageAccountName = $selectedStorage.StorageAccountName

# To Permanet deletions, disable Soft Delete for Blobs in the Storage account first.
$PERMANENT_DELETE_orListOnly ='List_Only'       # Set "PERMANENT_DELETE" to permanent delete all soft deleted objects
                                                # Set "List_Only" just to list without any deletion
                                                # Set "Count_Only" just to count without any deletion                                            

$containerName = ''             # Container Name, or empty to all containers

#----------------------------------------------------------------------
# the following options are NOT SUPPORTED for ADLS Gen2 accounts (only for Flat Name Space storage accounts)
#----------------------------------------------------------------------
$prefix = ''                    # Set prefix for scanning (optional) 
$blobType = 'All Types'         # valid values: 'Base' / 'Snapshots' / 'Versions' / 'Versions+Snapshots' / 'All Types' 
$accessTier = 'All'             # valid values: 'Hot', 'Cool', 'Archive', 'All' 
#----------------------------------------------------------------------

# Select blobs before Last Modified Date (optional) - if at least one value is empty, current date will be used
$Year = ''
$Month = ''
$Day = ''
#----------------------------------------------------------------------

$totalCount = 0
$arrDeleted2 = ''
$container_Token = $Null
#----------------------------------------------------------------------




#----------------------------------------------------------------------
# Validate parameters
#----------------------------------------------------------------------
if($storageAccountName -eq $Null) { 
    write-host "INVALID PARAMETER: Storage Account name" -ForegroundColor red 
    break 
}

if(($PERMANENT_DELETE_orListOnly -ne 'PERMANENT_DELETE') -and ($PERMANENT_DELETE_orListOnly -ne 'List_Only') -and ($PERMANENT_DELETE_orListOnly -ne 'Count_Only')) { 
    write-host "INVALID PARAMETER: PERMANENT_DELETE_orListOnly" -ForegroundColor red 
    break 
}

if(($blobType -ne 'Base') -and ($blobType -ne 'Versions') -and ($blobType -ne 'Snapshots') -and ($blobType -ne 'Versions+Snapshots') -and ($blobType -ne 'All Types')) { 
    write-host "INVALID PARAMETER: blobType" -ForegroundColor red 
    break 
}

if(($accessTier -ne 'Hot') -and ($accessTier -ne 'Cool') -and ($accessTier -ne 'Archive') -and ($accessTier -ne 'All')) { 
    write-host "INVALID PARAMETER: accessTier" -ForegroundColor red 
    break 
}
#----------------------------------------------------------------------



 
#----------------------------------------------------------------------
# Date format
#----------------------------------------------------------------------
if ($Year -ne '' -and $Month -ne '' -and $Day -ne '')
{
    $maxdate = Get-Date -Year $Year -Month $Month -Day $Day -ErrorAction Stop
}
else
{
    $maxdate = Get-Date
}
#----------------------------------------------------------------------
 



#----------------------------------------------------------------------
# Format String Details in user friendy format
#----------------------------------------------------------------------
switch($blobType) 
{
    'Base'               {$strBlobType = 'Base Blobs'}
    'Snapshots'          {$strBlobType = 'Snapshots'}
    'Versions+Snapshots' {$strBlobType = 'Versions & Snapshots'}
    'Versions'           {$strBlobType = 'Blob Versions only'}
    'All Types'          {$strBlobType = 'All blobs (Base Blobs + Versions + Snapshots)'}
}
if ($containerName -eq '') {$strContainerName = 'All Containers (except $logs)'} else {$strContainerName = $containerName}
#----------------------------------------------------------------------



#----------------------------------------------------------------------
# Show summary of the selected options
#----------------------------------------------------------------------
function ShowDetails ($storageAccountName, $strContainerName, $prefix, $strBlobType, $accessTier, $maxdate)
{
    # CLS
    if($selectedStorage.EnableHierarchicalNamespace -eq $true) {

        write-host " "
        write-host "Azure Storage - Permanent Delete Soft-Deleted Blob objects"
        write-host "-----------------------------------"

        write-host "Storage account: " -NoNewline 
        write-host "$storageAccountName - ADLS Gen2 Storage type" -ForegroundColor green 
        write-host "Container: $strContainerName"
        write-host "Prefix: not used"
        write-host "Blob Type: base"
        write-host "Blob Tier: not used"
        write-host "Last Modified Date before: $maxdate"
        write-host "-----------------------------------"

    } else {

        write-host " "
        write-host "Azure Storage - Permanent Delete Soft-Deleted Blob objects"
        write-host "-----------------------------------"

        write-host "Storage account: " -NoNewline 
        write-host "$storageAccountName - Flat Name Space Storage type" -ForegroundColor magenta 
        write-host "Container: $strContainerName"
        write-host "Prefix: '$prefix'"
        write-host "Blob Type: $strBlobType"
        write-host "Blob Tier: $accessTier"
        write-host "Last Modified Date before: $maxdate"
        write-host "-----------------------------------"
    }


}
#----------------------------------------------------------------------



#----------------------------------------------------------------------
#  --- ADLS Gen2 storage types (Hierarchical NameSpace enabled) ---
#  Filter and count files in some specific Fylesystem
#  List Files, Undelete Files & Permanet delete.
#  To Permanent Delete files, disable Soft Delete featue first at storage account level.
#----------------------------------------------------------------------
# Known Limitations:
# ------------------------
#  ADSLS Gen2 supports Soft Delete, No support for versions, Snapshots or Prefix (not coveresd by this script)
# ------------------------
# Message - The specified blob already exists:
#   To permanent delete a file, it needs first be undeleted. Having an active file with same name, the deleted one cannot be undeleted.
#   If that ocurrs, the script stops and no other files will be processed
#----------------------------------------------------------------------
function ADLSGen2FilesystemProcessing ($containerName)
{
    $fileCount = 0
    $arrDeleted = "Name", "Content Length", "RemainingRetentionDays", "Path" 
    $arrDeleted = $arrDeleted + "-------------", "-------------", "-------------", "-------------" 

    write-host -NoNewline "Processing filesystem $containerName...   " -ForegroundColor magenta 

    $ctx = New-AzStorageContext -BlobEndpoint "https://$storageAccountName.dfs.core.windows.net/" -UseConnectedAccount 

    do
    {
        # ADSLS Gen2 - List of all soft deleted files
        $items = Get-AzDataLakeGen2DeletedItem -FileSystem $containerName -Context $ctx -ContinuationToken $blob_Token -MaxCount 5000 -ErrorAction Stop
        if($items -eq $null) {
            break
        }


        # Prefix - Not used
        # Versions - Not supported on ADLS Gen2
        # Snapshots - Not supported on ADLS Gen2 
        # Blob Type always base blob
        # Filter by Access Tier - Not supported on ADLS Gen2

        # Only Soft-Deleted objects deleted before or equal $maxdate
        $listOfDeletedBlobs = $items | Where-Object { ($_.DeletedOn -le $maxdate) }

        $fileCount += $listOfDeletedBlobs.count


        # Permanent Delete those objects
        #-----------------------------------------
        if($PERMANENT_DELETE_orListOnly -eq "PERMANENT_DELETE") {

            $tmp = $listOfDeletedBlobs | Restore-AzDataLakeGen2DeletedItem -ErrorAction Stop

            foreach($file in $listOfDeletedBlobs)
            {
                Remove-AzDataLakeGen2Item -FileSystem $containerName -Path $file.Path -Context $ctx -Force  
            }
        }

        # List only objects
        #-----------------------------------------
        if ($PERMANENT_DELETE_orListOnly -eq 'List_Only') {
            foreach($file in $listOfDeletedBlobs)
            {
                $arrDeleted = $arrDeleted + ($file.Name,  $file.Length, $file.RemainingRetentionDays, $file.Path)
            }
        }
        #-----------------------------------------

        $blob_Token = $items[$items.Count -1].ContinuationToken;

    }while ($blob_Token -ne [string]::Empty)


    if($fileCount -eq 0) {
        write-host "No Objects found to list" -ForegroundColor red 
    } else {

        write-host " Soft Deleted Objects found: $fileCount "  -ForegroundColor magenta 

        if ($PERMANENT_DELETE_orListOnly -eq 'List_Only') {
            $arrDeleted | Format-Wide -Property {$_} -Column 4 -Force | out-string -stream | write-host -ForegroundColor Cyan
        }
    }
    #-----------------------------------------

    return $fileCount
}


#----------------------------------------------------------------------
#  --- Flat Name Space storage types ---
#  Filter and count blobs in some specific Container
#  List Blobs, Undelete blobs & Permanet delete
#  To Permanent Delete files, disable Soft Delete featue first at storage account level.
#----------------------------------------------------------------------
# Known Limitations:
# ------------------------
# Requires action Microsoft.Storage/storageAccounts/blobServices/containers/blobs/deleteBlobVersion/action
# or Storage Blob Data Owner RBAC role
#----------------------------------------------------------------------
function FlatContainerProcessing ($containerName)
{
    $blobCount = 0
    $arrDeleted = "Name", "Content Length", "Tier", "Snapshot Time", "Version ID", "Path" 
    $arrDeleted = $arrDeleted + "-------------", "-------------", "-------------", "-------------", "-------------", "-------------" 

    $blob_Token = $null
    $exception = $Null 

    $SASPermissions = 'rwdl'   # Permissions to SAS token do permanent Delete


    write-host -NoNewline "Processing container $containerName...   " -ForegroundColor magenta

    do
    {
        # Blob
        $listOfBlobs = Get-AzStorageBlob -Container $containerName -IncludeDeleted -IncludeVersion -Context $ctx -ContinuationToken $blob_Token -Prefix $prefix -MaxCount 5000 -ErrorAction Stop
        if($listOfBlobs -eq $null) {
            break
        }


        # Only Soft-Deleted objects with lastModifiedDate before or equal $maxdate
        $listOfDeletedBlobs = $listOfBlobs | Where-Object { ($_.LastModified -le $maxdate) -and ($_.IsDeleted -eq $true)}

        #Filter by Access Tier
        if($accessTier -ne 'All') 
           {$listOfDeletedBlobs = $listOfDeletedBlobs | Where-Object { ($_.accesstier -eq $accessTier)} }

        # Filter by Blob Type
        switch($blobType) 
        {
            'Base'               {$listOfDeletedBlobs = $listOfDeletedBlobs | Where-Object { $_.IsLatestVersion -eq $true -or ($_.SnapshotTime -eq $null -and $_.VersionId -eq $null) } }   # Base Blobs - Base versions may have versionId
            'Snapshots'          {$listOfDeletedBlobs = $listOfDeletedBlobs | Where-Object { $_.SnapshotTime -ne $null } }                                                                  # Snapshots
            'Versions+Snapshots' {$listOfDeletedBlobs = $listOfDeletedBlobs | Where-Object { $_.IsLatestVersion -ne $true -and (($_.SnapshotTime -eq $null -and $_.VersionId -ne $null) -or $_.SnapshotTime -ne $null) } }  # Versions & Snapshotsk
            'Versions'           {$listOfDeletedBlobs = $listOfDeletedBlobs | Where-Object { $_.IsLatestVersion -ne $true -and $_.SnapshotTime -eq $null -and $_.VersionId -ne $null} }     # Versions only 
            # 'All Types'        # All - Base Blobs + Versions + Snapshots

        }
 

        #----------------------------------------------------------------------
        # Uses REST API with SAS token call to permanent delete Blob
        # disable Soft Delete for Blobs in the Storage account, first
        #----------------------------------------------------------------------

        #sas for the rest api call to undelete (be careful to remove the question mark in front of the token)
        #-----------------------------------------
        $CurrentTime = Get-Date 
        $StartTime = $CurrentTime.AddHours(-1.0)
        $EndTime = $CurrentTime.AddHours(11.0)             # Max 10 hours to undelete all soft deleted objects for each container
 
        # Using Storage account key to generate a new SAS token ###
        $sas = New-AzStorageContainerSASToken -Name $containerName -Permission $SASPermissions -StartTime $StartTime -ExpiryTime $EndTime -Context $ctx
        $sas = $sas.Replace("?","")

        $blobCount += $listOfDeletedBlobs.Count



        # Undeleting the soft deleted blobs first, using Rest API, one by one
        #-----------------------------------------
        foreach($blob in $listOfDeletedBlobs)
        {
            
            if($PERMANENT_DELETE_orListOnly -eq "PERMANENT_DELETE") {
                $uri = "https://" + $blob.BlobClient.Uri.Host + $blob.BlobClient.Uri.AbsolutePath + “?comp=undelete&" + $sas
                try{
                  $res = Invoke-RestMethod -Method ‘Put’ -Uri $uri  
                } catch {
                    Write-Warning -Message "$_" -ErrorAction Stop
                    break
                }
                # write-host $uri
            }


            # DEBUG
            # write-host $blob.Name " Content-length:" $blob.Length " Access Tier:" $blob.accesstier " LastModified:" $blob.LastModified  " SnapshotTime:" $blob.SnapshotTime " URI:" $blob.ICloudBlob.Uri.AbsolutePath  " IslatestVersion:" $blob.IsLatestVersion  " Lease State:" $blob.ICloudBlob.Properties.LeaseState  " Version ID:" $blob.VersionID

            # Creates a table to show the Soft Delete objects
            #--------------------------------------------------
            if($PERMANENT_DELETE_orListOnly -eq "List_Only") {
                if($blob.SnapshotTime -eq $null) {$strSnapshotTime = "-"} else {$strSnapshotTime = $blob.SnapshotTime}
                if($blob.VersionID -eq $null) {$strVersionID = "-"} else {$strVersionID = $blob.VersionID}
                $arrDeleted = $arrDeleted + ($blob.Name, $blob.Length, $blob.AccessTier, $strSnapshotTime, $strVersionID, $blob.ICloudBlob.Uri.AbsolutePath)
            }
            #----------------------------------------------------------------------
        }


        # Permanent Delete those objects in one call
        #-----------------------------------------
        if($PERMANENT_DELETE_orListOnly -eq "PERMANENT_DELETE") {
            $tmp = $listOfDeletedBlobs | Remove-AzStorageBlob -Context $ctx 
        }

        $blob_Token = $listOfBlobs[$listOfBlobs.Count -1].ContinuationToken;

    }while ($blob_Token -ne $null)


    if($blobCount -eq 0) {
        write-host "No Objects found to list"  -ForegroundColor Red
    } else {    

        write-host " Soft Deleted Objects found: $blobCount  " -ForegroundColor magenta

        if($PERMANENT_DELETE_orListOnly -eq 'List_Only') { 
            if ($blobCount -gt 0) {
                $arrDeleted | Format-Wide -Property {$_} -Column 6 -Force | out-string -stream | write-host -ForegroundColor Cyan
            }
        }
    }


    return $blobCount
}
#----------------------------------------------------------------------





#----------------------------------------------------------------------
#                MAIN
#----------------------------------------------------------------------

ShowDetails $storageAccountName $strContainerName $prefix $strBlobType $accessTier $maxdate


# Permanent Delete warning
#---------------------------------------------------------------------
if($PERMANENT_DELETE_orListOnly -eq "PERMANENT_DELETE") {
$wshell = New-Object -ComObject Wscript.Shell
$warning = "You selected to Permanent Delete Soft-Deleted blobs.`n"
$warning = $warning + "You cannot recover these blobs anymore.`n"
$warning = $warning + "To proceed on this, please make sure you have Blob Soft Delete feature disabled at Storage account level.`n"
$warning = $warning + "You may reenable Blob Soft Delete feature again after finishing this script.`n`n"
$warning = $warning + "Do you want to continue?"
$answer = $wshell.Popup($warning,0,"Alert",64+4)
if($answer -eq 7){exit}
}
#---------------------------------------------------------------------




# Generic context to HierarchicalNameSpave and Flat Name sapce to list containers/filesystems
$ctx = New-AzStorageContext -StorageAccountName $storageAccountName -UseConnectedAccount 

$objCount=0

# Looping Containers
#----------------------------------------------------------------------
do {
        
    $containers = Get-AzStorageContainer -Context $ctx -Name $containerName -ContinuationToken $container_Token -MaxCount 5000 -ErrorAction Stop
    
        
    if ($containers -ne $null)
    {
        $container_Token = $containers[$containers.Count - 1].ContinuationToken

        for ([int] $c = 0; $c -lt $containers.Count; $c++)
        {
            $container = $containers[$c].Name

            # HierarchicalNameSpace enabled 
            #----------------------------------------------------------
            if($selectedStorage.EnableHierarchicalNamespace -eq $true) {
                $objCount = ADLSGen2FilesystemProcessing ($container)
            } else { 
            # Flat name space storage type
            #----------------------------------------------------------
                $objCount = FlatContainerProcessing ($container)
            }

            $totalCount += $objCount
        }
    }

} while ($container_Token -ne $null)
#----------------------------------------------------------------------

write-host "Total objects processed: $totalCount "  -ForegroundColor magenta 
