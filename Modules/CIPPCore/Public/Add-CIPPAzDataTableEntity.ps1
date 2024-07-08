function Add-CIPPAzDataTableEntity {
    [CmdletBinding()]
    param(
        $Context,
        $Entity,
        [switch]$Force,
        [switch]$CreateTableIfNotExists
    )

    $MaxRowSize = 500000 - 100 #Maximum size of an entity
    $MaxSize = 30kb # maximum size of a property value

    foreach ($SingleEnt in $Entity) {
        try {
            Add-AzDataTableEntity -context $Context -force:$Force -CreateTableIfNotExists:$CreateTableIfNotExists -Entity $SingleEnt -ErrorAction Stop
        } catch [System.Exception] {
            if ($_.Exception.ErrorCode -eq 'PropertyValueTooLarge' -or $_.Exception.ErrorCode -eq 'EntityTooLarge') {
                try {
                    $largePropertyNames = @()
                    $entitySize = 0
                    foreach ($key in $SingleEnt.Keys) {
                        $propertySize = [System.Text.Encoding]::UTF8.GetByteCount($SingleEnt[$key].ToString())
                        $entitySize = $entitySize + $propertySize
                        if ($propertySize -gt $MaxSize) {
                            $largePropertyNames = $largePropertyNames + $key
                        }
                    }

                    if ($largePropertyNames.Count -gt 0) {
                        foreach ($largePropertyName in $largePropertyNames) {
                            $dataString = $SingleEnt[$largePropertyName]
                            $splitCount = [math]::Ceiling($dataString.Length / $MaxSize)
                            $splitData = @()
                            for ($i = 0; $i -lt $splitCount; $i++) {
                                $start = $i * $MaxSize
                                $splitData = $splitData + $dataString.Substring($start, [Math]::Min($MaxSize, $dataString.Length - $start))
                            }

                            $splitPropertyNames = @()
                            for ($i = 0; $i -lt $splitData.Count; $i++) {
                                $splitPropertyNames = $splitPropertyNames + "${largePropertyName}_Part$i"
                            }

                            $splitInfo = @{
                                OriginalHeader = $largePropertyName
                                SplitHeaders   = $splitPropertyNames
                            }
                            $SingleEnt['SplitOverProps'] = ($splitInfo | ConvertTo-Json).ToString()
                            $SingleEnt.Remove($largePropertyName)

                            for ($i = 0; $i -lt $splitData.Count; $i++) {
                                $SingleEnt[$splitPropertyNames[$i]] = $splitData[$i]
                            }
                        }
                    }

                    # Check if the entity is still too large
                    $entitySize = [System.Text.Encoding]::UTF8.GetByteCount($($SingleEnt | ConvertTo-Json))
                    if ($entitySize -gt $MaxRowSize) {
                        $rows = @()
                        $originalPartitionKey = $SingleEnt.PartitionKey
                        $originalRowKey = $SingleEnt.RowKey
                        $entityIndex = 0

                        while ($entitySize -gt $MaxRowSize) {
                            Write-Host "Entity size is $entitySize. Splitting entity into multiple parts."
                            $newEntity = @{}
                            $newEntity['PartitionKey'] = $originalPartitionKey
                            $newEntity['RowKey'] = "$($originalRowKey)-part$entityIndex"
                            $newEntity['OriginalEntityId'] = $originalRowKey
                            $newEntity['PartIndex'] = $entityIndex
                            $entityIndex++

                            $propertiesToRemove = @()
                            foreach ($key in $SingleEnt.Keys) {
                                $newEntitySize = [System.Text.Encoding]::UTF8.GetByteCount($($newEntity | ConvertTo-Json))
                                if ($newEntitySize -lt $MaxRowSize) {
                                    $propertySize = [System.Text.Encoding]::UTF8.GetByteCount($SingleEnt[$key].ToString())
                                    if ($propertySize -gt $MaxRowSize) {
                                        $dataString = $SingleEnt[$key]
                                        $splitCount = [math]::Ceiling($dataString.Length / $MaxSize)
                                        $splitData = @()
                                        for ($i = 0; $i -lt $splitCount; $i++) {
                                            $start = $i * $MaxSize
                                            $splitData = $splitData + $dataString.Substring($start, [Math]::Min($MaxSize, $dataString.Length - $start))
                                        }

                                        $splitPropertyNames = @()
                                        for ($i = 0; $i -lt $splitData.Count; $i++) {
                                            $splitPropertyNames = $splitPropertyNames + "${key}_Part$i"
                                        }

                                        for ($i = 0; $i -lt $splitData.Count; $i++) {
                                            $newEntity[$splitPropertyNames[$i]] = $splitData[$i]
                                        }
                                    } else {
                                        $newEntity[$key] = $SingleEnt[$key]
                                    }
                                    $propertiesToRemove = $propertiesToRemove + $key
                                }
                            }

                            foreach ($prop in $propertiesToRemove) {
                                $SingleEnt.Remove($prop)
                            }

                            $rows = $rows + $newEntity
                            $entitySize = [System.Text.Encoding]::UTF8.GetByteCount($($SingleEnt | ConvertTo-Json))
                        }

                        if ($SingleEnt.Count -gt 0) {
                            $SingleEnt['RowKey'] = "$($originalRowKey)-part$entityIndex"
                            $SingleEnt['OriginalEntityId'] = $originalRowKey
                            $SingleEnt['PartIndex'] = $entityIndex
                            $SingleEnt['PartitionKey'] = $originalPartitionKey

                            $rows = $rows + $SingleEnt
                        }

                        foreach ($row in $rows) {
                            Write-Host "current entity is $($row.RowKey) with $($row.PartitionKey). Our size is $([System.Text.Encoding]::UTF8.GetByteCount($($SingleEnt | ConvertTo-Json)))"
                            Add-AzDataTableEntity -context $Context -force:$Force -CreateTableIfNotExists:$CreateTableIfNotExists -Entity $row
                        }
                    } else {
                        Add-AzDataTableEntity -context $Context -force:$Force -CreateTableIfNotExists:$CreateTableIfNotExists -Entity $SingleEnt
                    }

                } catch {
                    throw "Error processing entity: $($_.Exception.Message)."
                }
            } else {
                Write-Host "THE ERROR IS $($_.Exception.ErrorCode). The size of the entity is $entitySize."
                throw $_
            }
        }
    }
}
