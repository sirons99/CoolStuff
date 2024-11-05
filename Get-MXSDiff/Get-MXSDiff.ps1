<#
.SYNOPSIS
Create MXS files from Maximo Asset Manager 7.6.x.x

.DESCRIPTION
This script queries the XML data for each Screen in the MAXPRESENTATION table on both the Source and Destination systems, then  There are two modalities:
    Bulk Difference - Iterate through every Screen in the Source and Destination databases to produce MXS files for all differences.
    Ad-Hoc - Specify the Source and Destination databases and the Screen to get differences for

The default MAXIMO_HOME value is hardcoded for convenience on the systems this was tested on, but it can be overridden.

Initially I was going to just steal the data from SQL, but there's already a class file that does the work for us (mxexportpresentation.class)

This script should be executed on a Maximo application server for convenience, and the user should have access to the maximo.properties files on other environments.

NOTE: Existing files created by this tool will be overwritten so be mindful of what you're doing!

.PARAMETER MaximoHome
Override the default path for MAXIMO_HOME; useful if you have multiple Maximo instances installed.

.PARAMETER All
Enumerate all Screens on the source environment and difference them against the destination environment.

.PARAMETER Cleanup
Delete the exported XML files after the difference file has been created, and also delete 'empty' difference files. Note that a list of 'skipped'
difference files will be listed in c:\temp.

.PARAMETER Screen
The name of the Screen to create a difference file for. 

.PARAMETER Source
Specify the source environment. An enumerated option list is available. 

.PARAMETER Destination
Specify the destination environment. An enumerated option list is available.

.PARAMETER OutFile
(Optional) Specify the name of the output file, which will show up in %MAXIMO_HOME%\tools\maximo\en. If no name is supplied, then a name will
be created, such as Asset-DEVtoTEST.mxs.

.Parameter StartingOutFile
(Optional) Specify a starting OutFile in the format 'whatever_yy', where yyy is the beginning ordinal you want to use for a bulk/sequetial import.
Normally this would look like 'V1000_06'. If yyy is not numeric, something wierd will happen because I'm not checking for that. If no name is
supplied, then a name will be created, such as Asset-DEVtoTEST.mxs. Note that 'doing all' means a couple hundred screens. TODO: Not sure if 
Maximo import tools support three digits?

.PARAMETER CreateUndo
(Optional) This will create an inverse difference file, which will essentially 'undo' whatever the difference file changes.

.EXAMPLE
Basic Difference:
    Get-MXSDiff -Source DEV -Destination TEST -Screen Inventory
    This will create a difference file named Inventory-DEVtoTEST.mxs, which if applied to the TEST environment would make that screen match DEV

Slightly Less Basic Difference:
    Get-MXSDiff -Source TEST -Destination PROD -Screen Assets -Outfile V1000_09 -CreateUndo
    This will create a difference file named V1000_09.mxs and also a file named V1000_09-Undo.mxs.

.NOTES
This was tested with Maximo Asset Manager 7.6.1.3. No idea if this will work on MAS 9.

Created for funsies in October 2024 by Mike Hoeppner
#>
param(    
    [string]$MaximoHome = "c:\IBM\SMP\maximo",
    [Parameter(ParameterSetName='DoAll')]    
    [switch]$All,  
    [Parameter(Mandatory=$true,ParameterSetName='Adhoc')]
    [string]$Screen,   
   # [Parameter(Mandatory=$true,ParameterSetName='Adhoc')]
   # [Parameter(Mandatory=$true,ParameterSetName='DoAll')]
    [ValidateSet('DEV','TEST','PROD')]
    [string]$Source,
   # [Parameter(Mandatory=$true,ParameterSetName='Adhoc')]
   # [Parameter(Mandatory=$true,ParameterSetName='DoAll')]
    [ValidateSet('DEV','TEST','PROD')]
    [string]$Destination,
    [Parameter(ParameterSetName='Adhoc')]    
    [string]$OutFile,
    [Parameter(ParameterSetName='DoAll')]
    [string]$StartingOutFile,
    [switch]$CreateUndo,
    [switch]$Cleanup
)

#region Constants

######################  Comment this before using in production for -All  ######################
#$debugLimiter = "TOP 10"
################################################################################################

$javaExePath = Join-Path -Path $MaximoHome -ChildPath "tools\java\jre\bin\java.exe"
$outPath = Join-Path -Path $MaximoHome -ChildPath "tools\maximo\en"
$toolRoot = Join-Path -Path $MaximoHome -ChildPath "tools\maximo"
$exportPath = Join-Path -Path $MaximoHome -ChildPath "\tools\maximo\screen-upgrade"
$skipPath = "c:\temp"

#TODO: This can be expanded to include additional maximo systems; just remember to update the ValidateSet attribute on the Source
#      and Destination parameters
$propFiles = @{
    DEV = "\\nf-maximodev1\c$\IBM\SMP\maximo\applications\maximo\properties\maximo.properties"
    TEST = "\\nf-maximotest1\c$\IBM\SMP\maximo\applications\maximo\properties\maximo.properties"
    PROD = "\\nf-maximoprod1\c$\IBM\SMP\maximo\applications\maximo\properties\maximo.properties"
}

$MXExportPresentationArgs = "-classpath {0};{1}\classes;{2} psdi.webclient.upgrade.MXExportPresentation {3} {4}"
$MXDiffArgs = "-classpath {0};{1}\classes;{2} psdi.webclient.upgrade.MXScreenDiff {3} {4} {5}"

$outFileTemplate = "{0}-{1}to{2}"

$jdbcProp = "mxe.db.url"
$connString = "Server={0},{1};Database={2};Integrated Security=true;"
#$connString = "Server={0},{1};Database={2};Integrated Security=false;User ID=scripttest;Password=blah"
$screenQuery = ("SELECT {0}app,maxpresentationid FROM MAXPRESENTATION" -f $debugLimiter)

enum GetMXSResult{
    Error = -1
    Created = 0
    Empty = 1
    MissingSource = 2
    MissingDestination = 3
}

#endregion

#region Methods

#This duplicates the functionality of the commonenv.bat script so that the environment variables are inherited by the java process. The Maximo root should be passed in
function Set-CommonEnv {
    param (
        $MaximoHome
    )
    
    #I'm not sure which of these are needed by Java so we're doing them all as environment variables.
    $env:MAXIMO_HOME="$MaximoHome"    
    $env:MAXIMO_ROOT="$($env:MAXIMO_HOME)\applications\maximo"    
    $env:MAXIMO_LIB_PATH="$($env:MAXIMO_ROOT)\lib"    
    $env:MAXIMO_COMMON_LIBS="$($env:MAXIMO_ROOT)\properties;$($env:MAXIMO_ROOT)\resources;$($env:MAXIMO_ROOT)\businessobjects\classes;$($env:MAXIMO_ROOT)\maximouiweb\webmodule\WEB-INF\classes;$($env:MAXIMO_LIB_PATH)\j2ee.jar;$($env:MAXIMO_LIB_PATH)\bcel-6.6.1.jar;$($env:MAXIMO_LIB_PATH)\tools.jar;$($env:MAXIMO_LIB_PATH)\icu4j.jar;$($env:MAXIMO_LIB_PATH)\json4j.jar;$($env:MAXIMO_LIB_PATH)\gson-2.8.9.jar;$($env:MAXIMO_LIB_PATH)\aws-java-sdk-core-1.12.267.jar;$($env:MAXIMO_LIB_PATH)\aws-java-sdk-kms-1.12.267.jar;$($env:MAXIMO_LIB_PATH)\aws-java-sdk-s3-1.12.267.jar;$($env:MAXIMO_LIB_PATH)\jackson-dataformat-cbor-2.12.3.jar;$($env:MAXIMO_LIB_PATH)\jmespath-java-1.12.54.jar;$($env:MAXIMO_LIB_PATH)\ion-java-1.10.5.jar;$($env:MAXIMO_LIB_PATH)\commons-codec-1.15.jar;$($env:MAXIMO_LIB_PATH)\log4j-1.2-api-2.17.1.jar;$($env:MAXIMO_LIB_PATH)\log4j-core-2.17.1.jar;$($env:MAXIMO_LIB_PATH)\log4j-api-2.17.1.jar;$($env:MAXIMO_LIB_PATH)\jackson-annotations-2.15.1.jar;$($env:MAXIMO_LIB_PATH)\jackson-core-2.15.1.jar;$($env:MAXIMO_LIB_PATH)\jackson-core-asl-1.9.13.jar;$($env:MAXIMO_LIB_PATH)\jackson-databind-2.15.1.jar;"
    $env:MAXIMO_DB_LIBS="$($env:MAXIMO_LIB_PATH)\oraclethin.jar;$($env:MAXIMO_LIB_PATH)\sqljdbc.jar;$($env:MAXIMO_LIB_PATH)\Opta.jar;$($env:MAXIMO_LIB_PATH)\db2jcc.jar;$($env:MAXIMO_LIB_PATH)\db2jcc_license_cu.jar;$($env:MAXIMO_LIB_PATH)\jaxen-1.1-beta-8.jar;$($env:MAXIMO_LIB_PATH)\jtds-1.3.1.jar;"
    $env:MAXIMO_XML_LIBS="$($env:MAXIMO_LIB_PATH)\jdom.jar;$($env:MAXIMO_LIB_PATH)\xercersImpl.jar"
    $env:MAXIMO_MEA_LIBS="$($env:MAXIMO_LIB_PATH)\jaxrpc.jar;$($env:MAXIMO_LIB_PATH)\saaj.jar;$($env:MAXIMO_LIB_PATH)\uddi4j.jar;$($env:MAXIMO_LIB_PATH)\wsdl4j.jar;$($env:MAXIMO_LIB_PATH)\jaxen-full.jar;$($env:MAXIMO_LIB_PATH)\saxpath.jar;;$($env:MAXIMO_LIB_PATH)\commons-discovery.jar;$($env:MAXIMO_LIB_PATH)\commons-logging-1.2.jar;$($env:MAXIMO_LIB_PATH)\axis.jar;$($env:MAXIMO_LIB_PATH)\axis-ant.jar;$($env:MAXIMO_XML_LIBS)"
    $env:MAXIMO_CLASSPATH="$PSScriptRoot;$($env:MAXIMO_COMMON_LIBS);$($env:MAXIMO_DB_LIBS);$($env:MAXIMO_XML_LIBS)"
    $env:MEMORY_ARGS="-Xmx1024m"
}
# Enumerate all screens in the source environment and difference them against the destination.
function Export-All {
    param(
        $exaSource,
        $exaDestination,
        $exaOutFileBase,
        [switch]$exaUndo
    )

    #We need to use the Source to query a list of screens, then iterate through that list to produce the outfiles
    $cndata = Convert-JdbcURL -URL (Get-JdbcURL -PathToPropertiesFile $propFiles[$exaSource])

    #Get array of DataRow objects from SQL. Note that the unique ID is included for future use (at the moment names are unique)
    [System.Data.DataRowCollection]$screens = Get-ScreenList -Server $cndata['serverName'] -Database $cndata['databaseName'] -Port $cndata['portNumber']

    #If no OutFileBase is specified, the Get-MXS method will generate one.
    #If it IS specified, we need to determine the starting ordinal assuming the format whatever_yyy
    #for simplicity, the iterator will track the counter no matter what and also NOT increment if there are skips.
    $isUsingBase = !([string]::IsNullOrEmpty($exaOutFileBase))

    $baseName = $null
    $currentName = $null
    $counter = -1
   
    #carve up OutFileBase
    if ($isUsingBase) {
        $bits = $exaOutFileBase -split '_'
        $baseName = "$($bits[0])"
        $counter = [int]$bits[1]
        if ($counter -eq -1) {Write-Error "The supplied base name $exaOutFileBase could not be parsed and the developer is too lazy to handle it."}
    }

    #iterate through list of screens and invoke Get-MXS for each
    foreach ($screen in $screens) {
        #Generate filename if we're doing that
        if ($isUsingBase){
            #on first run, the ordinal will be what the user wants to start with. each successful iteration will increment the counter
            $currentName = "{0}_{1:d3}" -f $baseName,$counter
        }
        #invoke get-MXS and handle enumerated results
        $result = (Get-MXS -mxsScreen $screen.app -mxsSource $exaSource -mxsDestination $exaDestination -DoAll -mxsUndo:($exaUndo.IsPresent) -mxsOutfile $currentName)

        switch ($result) {
            ([GetMXSResult]::Created)  {
                write-host "Created file $($currentName).mxs for screen $($screen.app) (ID=$($screen.maxpresentationid))." -ForegroundColor green
                $counter++
            }

            ([GetMXSResult]::MissingDestination) {
                    write-host "Screen $($screen.app) (ID=$($screen.maxpresentationid)) does not exist in $exaDestination"
            }
            
            ([GetMXSResult]::Empty) {
                write-host "Created file $($currentName).mxs for screen $($screen.app) (ID=$($screen.maxpresentationid)), but we deleted it because it was empty and -Cleanup was specified." -ForegroundColor Yellow                
            }

            ([GetMXSResult]::Error) {
                write-host "An error occurred while processing Screen $($screen.app) (ID=$($screen.maxpresentationid))!" -ForegroundColor Red
            }
            #Can't have missing source if we're running from a list from the source
            default {
                write-host "Invocation of Get-MXS returned something unexpected ($result). This shouldn't happen."
            }
        }
       
    } #repeat loop
}

# Validate parameters and perform a single invocation of MXExportPresentation.class.
function Invoke-MXExport {
    param(
        $exScreen,
        $exProps,
        $label
    )

    #prepend arguments
    $exScreenArg = "-a$exScreen"
    $exPropsArg = " -p""$exProps"""

    #format argument string; because the original use of %MAXIMO_CLASSPATH% didn't seem to work we're kludging it in
    $jArgs = ($MXExportPresentationArgs -f $toolRoot,$toolRoot,$env:MAXIMO_CLASSPATH, $exScreenArg,$exPropsArg)

    #args are prepped, time to execute. 
    Start-Process -Wait -NoNewWindow -WorkingDirectory $exportPath -FilePath $javaExePath -ArgumentList $jArgs

    #TODO: Not sure if we'd get error codes back, could put error handling here.
    #Determine the outfile path
    $exportedFile = Join-Path -Path $exportPath -ChildPath ("$exScreen.xml")
   
    #validate file exists and run scrubbing
    if(Test-Path -Path $exportedFile -PathType Leaf) {
        #Good, the exported file exists. Now we rename it so it doesn't get stomped by subsequent operations.
        $file = Get-ChildItem -path $exportedFile -File
        $newName ="$($file.BaseName)-$label$($file.Extension)"
        #delete old fie if it exists
        Remove-Item -Path (join-path -path $exportPath -ChildPath $newName) -force -Confirm:$false -ErrorAction SilentlyContinue | out-null
        $newFile = Rename-Item -Path $exportedFile -NewName $newName -PassThru -Force
        #TODO: Add any processing here. Keep in mind $newFile is a FileInfo object
        return $newFile.FullName
    }
    else {
    Write-Warning "Could not confirm that $exportedFile exists; this could be caused by an invalid screen name. `
                    This could be normal if a Screen exists in one environment but not the other."     
        return $null       
    }
}

#Invokes the MXScreenDiff.class to compare two Screen exports and produce a difference file.
function Get-MXSDifferenceFile {
    param(
        $diffSource,
        $diffDestination,
        $diffOutfile
    )

    #prepend arguments
    $diffSourceArg = "-m""$diffSource"""
    $diffDestinationArg = "-b""$diffDestination"""
    $diffOutfileArg = "-t$diffOutfile.mxs"
  

    #format argument string; because the original use of %MAXIMO_CLASSPATH% didn't seem to work we're kludging it in
    $jArgs = ($MXDiffArgs -f $toolRoot,$toolRoot,$env:MAXIMO_CLASSPATH, $diffSourceArg,$diffDestinationArg,$diffOutfileArg)

    #args are prepped, time to execute. 
    Start-Process -Wait -NoNewWindow -WorkingDirectory $exportPath -FilePath $javaExePath -ArgumentList $jArgs

    #TODO: Not sure if we'd get error codes back, could put error handling here.
    
    #not much else to do at this point.
}

#Converts a JDBC URL string into a hashtable. Properties of interest are portNumber, serverName, databaseName
function Convert-JdbcURL {
    param (
        $URL
    )
    # Parse into array
    $bits = $URL -split ';'

    #Return hashtable
    return ConvertFrom-StringData -StringData ($bits[1..$($bits.Count -1)] | out-string)
}

#Create .Net SQL Server Connection String. In this context we're assuming AD authentication.
function Get-ScreenList {
    param (
        $Server,
        $Database,
        $Port
    )

    #Create connection object
    $sqlConn = New-Object System.Data.SqlClient.SqlConnection
    $sqlConn.ConnectionString = ($connString -f $Server,$Port,$Database)

    #Create command object
    $sqlCmd = New-Object System.Data.SqlClient.SqlCommand
    $sqlCmd.CommandText = $screenQuery
    $sqlCmd.Connection = $sqlConn  

    #create data adapter to fill table
    $sqldt = New-Object System.Data.DataTable
    $sqlda = New-Object System.Data.SqlClient.SqlDataAdapter
    $sqlda.SelectCommand = $sqlCmd

    #fill the datatable
    try
    {
        $sqlConn.Open()
        $sqlda.Fill($sqldt) | Out-Null
    }
    catch
    {
        Write-Error "Error reading screen list on database [$Database] on server [$Server]!"
    }
    finally {
        $sqlConn.Close()
        $sqlConn.Dispose()
    }

    #return just the datarow collection
    return , $sqldt.Rows
}

#Fetches JDBC URL from a maximo.properties file.
function Get-JdbcURL {
    param(
        $PathToPropertiesFile
    )
    #Read in the data as a hashtable
    #Well, this fails if there are duplicates so we have to do it manually. 
    #$content = ConvertFrom-StringData -StringData (Get-Content $PathToPropertiesFile -Raw)
    #Convert to array and find first instance beginning with the property string
    #Should only be one, but if there weren't duplicates we'd do this the easy way.
    $line = (Get-Content -Path $PathToPropertiesFile | select-string -Pattern "^$($jdbcProp).+")[0]
    $jdbc = ($line -split $jdbcProp)[1]

    return $jdbc
}

#Encapsulates all of the logic for the ad-hoc difference file creation and adds the 'DoAll' switch to bypass error checking
#Later added enumerated return codes
function Get-MXS {
    param (
        $mxsScreen,
        $mxsSource,
        $mxsDestination,
        $mxsOutfile,
        [switch]$mxsUndo,
        [switch]$DoAll
    )
    #Get the source file first
    $SourceFile = Invoke-MXExport -exScreen $mxsScreen -exProps $propFiles[$mxsSource] -label $mxsSource
    
    #get the destination file
    $DestinationFile = Invoke-MXExport -exScreen $mxsScreen -exProps $propFiles[$mxsDestination] -label $mxsDestination
    
    #Construct outfile name if necessary
    #Note that in DoAll mode, the caller is generating the Outfile name and iterating
    if ($mxsOutFile) {
        #trim filename if someone put an extension on it. If you really want to create V1000_01.something.mxs, comment this line out.
        $outFileName = [System.IO.Path]::GetFileNameWithoutExtension($mxsOutfile)
    }
    else {
        $outFileName = ($outFileTemplate -f $mxsScreen, $mxsSource,$mxsDestination)
    }

    if (!($DoAll.IsPresent)) {
        #Check for missing Screens and exit if this is ad-hoc
        if ($SourceFile -eq $null -and $DestinationFile -ne $null){
            Write-Warning "The Screen $mxsScreen is present on $mxsDestination, but not on $mxsSource. No MXS file can be created."
            exit [GetMXSResult]::MissingSource
        }
        if ($SourceFile -ne $null -and $DestinationFile -eq $null){
            throw [System.NotImplementedException]::new("The Screen $mxsScreen exists on $mxsSource but not on $mxsDestination; building new screens has not been tested yet.")
            exit [GetMXSResult]::MissingDestination
        }
        
        if ($SourceFile -eq $null -and $DestinationFile -eq $null){
            Write-Warning "Screen $mxsScreen does not seem to exist in either environments, or an error has occurred."
            exit [GetMXSResult]::Error
        }    
    }   
    else {
        #There shouldn't be missing Source files because we are using the Source database to enumerate them.
        #If Destination doesn't exist, we just need to return False so the caller can make a note of it.
        if ($DestinationFile -eq $null) {return [GetMXSResult]::MissingDestination}
    }

    #Implicitly both filenames are not null at this point so create the diff file
    #TODO: This will not catch failures of mxexport on source in 'DoAll' mode!
    Get-MXSDifferenceFile -diffSource $SourceFile -diffDestination $DestinationFile -diffOutfile $outFileName

    #Determine full path to MXS file
    $actualOutfile = Join-Path -Path $exportPath -ChildPath ("$outFileName.mxs")

    #Determine whether or not the outfile contains any changes
    $mxsIsEmpty = Detect-EmptyMXS -fileName $actualOutfile
      
    #See if an undo script is wanted AND the differencing file isn't empty (can't undo zero changes)
    if ($mxsUndo.IsPresent -and !($mxsIsEmpty)){
        #Simply reverse the polarity...
        Get-MXSDifferenceFile -diffSource $DestinationFile -diffDestination $SourceFile -diffOutfile "$outFileName-undo"
    }  

     #If Cleanup mode is on, delete the XML files because we don't need them anymore, and also delete empty MXS files
     if ($Cleanup.IsPresent) {
        Remove-Item -Path $SourceFile | Out-Null
        Remove-Item -Path $DestinationFile | Out-Null

        if($mxsIsEmpty){
            #log the skip and remove the file
            $outFileName | Add-Content -path $skipfile
            Remove-Item -Path $actualOutfile | Out-Null
            return [GetMXSResult]::Empty
        }
    } 
    #At this point, we assume an MXS file that was not empty has been created
    return [GetMXSResult]::Created 
} 

#This method reads an MXS file and determines whether or not it is 'empty' (i.e. contains no changes)
function Detect-EmptyMXS {
    param (
        $fileName
        )
    #as far as I can tell, an 'empty' file will not have a closing tag for <updatescript>, so the presence of a closing tag indicates its
    #not empty
    #for speed, we're not going to read the entire file, just the last few lines
    return (!((Get-Content -Tail 5 -Path $fileName | ForEach-Object {$_ -match "</updatescript>"}) -contains $true))
}

#endregion

#main

#Make sure we can find JRE; it's a short trip otherwise
if(!(Test-Path -Path $javaExePath)) {
    write-error "Could not verify JRE available. Please check $javaExePath to make sure JRE is present."
    exit 1
}

#Create skip file if Cleanup mode is on
if ($Cleanup.IsPresent) {
    $thisScript = (split-path -Path $PSCommandPath -Leaf) -replace ".ps1",""
    $skipfile = ("c:\temp\$thisscript-skipped{0}.log" -f (get-date -format "yyyyMMdd-hhmmss"))
    [System.IO.Directory]::CreateDirectory((Split-Path -Path $skipfile -Parent)) | Out-Null     
}

#Set environment variables
Set-CommonEnv -MaximoHome $MaximoHome

#Determine if we're bulk-exporting or doing an ad-hoc
if ($All.IsPresent) {

    Export-All -exaSource $Source -exaDestination $Destination -exaOutFileBase $StartingOutFile -exaUndo:($CreateUndo.IsPresent)
    exit
}

#okay, we're doing an ad-hoc MXS Differencing. Since this is nearly identical to the DoAll operation I'm refactoring it out of main

$result = Get-MXS -mxsScreen $Screen -mxsSource $Source -mxsDestination $Destination -mxsOutfile $OutFile -mxsUndo:($CreateUndo.IsPresent) 

#end