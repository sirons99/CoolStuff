<#
.SYNOPSIS
Create DBC files from Maximo Asset Manager 7.6.x.x

.DESCRIPTION
This script encapsulates the geninsertdbc.jar file that comes with Maximo to query the database and export a series of insert commands to a DBC file (which 
is basically XML). There are two modalities:
    Bulk Load - use the -FromCSV option to load a CSV file with the structure Table,Where,Outfile. This mode will iterate through the CSV and produce each DBC file.
    Ad-Hoc - Specify the Table, Where Clause, and Out File to get a single DBC file

The default MAXIMO_HOME value is hardcoded for convenience on the systems this was tested on, but it can be overridden.

By default, this script will 'scrub' the resulting DBC file to eliminate columnvalue elements that have empty properties. This can be disabled with the -NoScrub
option.

The geninsertdbc.jar file should use whatever database is specified in the settings and whatever JDBC adapter is required. This was only tested with SQL Server.

This script should be executed on a Maximo application server.

.PARAMETER MaximoHome
Override the default path for MAXIMO_HOME; useful if you have multiple Maximo instances installed.

.PARAMETER FromCSV
Provides the full path of a CSV file to direct a series of DBC exports.

.PARAMETER NoScrub
No, I don't want no scrub...  this switch disables the 'scrubbing' logic that cleans up the DBC exports.

.PARAMETER Table
Specify the table you want to export. Note that you are responsible for understanding relationships between tables (such as Person, Maxuser, and Email).

.PARAMETER Where
(Optional) Specify the 'where' clause to limit the results of the DBC export. You need to use double quotes because of spaces.

.PARAMETER OutFile
Specify the name of the output file, which will show up in %MAXIMO_HOME%\tools\maximo\en\script". The .dbc will be appended automatically.

.EXAMPLE
Basic example:
    Export-MaximoDBC -Table applicationauth -OutFile V1000_02

Where example:
    Export-MaximoDBC -Table applicationauth -OutFile V1000_02 -Where "app in ('MXL_COMMODITIES','MXL_COMPANIES','MXL_COMPCONTACT','MXL_COMPCONTACTMASTE','MXL_INVCOST','MXINVENTORY2','MXITEM2','MXL_PM')"

 Bulk Export example:
    Export-MaximoDBC -FromCSV "c:\temp\severaltables.csv"

.NOTES
This was tested with Maximo Asset Manager 7.6.1.3. No idea if this will work on MAS 9, but unless the invocation of the jar file changes it should still
work in theory with a few tweaks to make it Linux-compatible (directory separators and java executable, for starters). Oh, and installing PowerShell inside a 
container will be delightful... so it's probably best to provide the JDBC and config files externally for this script.

Bulk exports have a 1:1 relationship between tables and outfiles. I've considered adding logic that detects an existing DBC file, renames it, runs the latest 
export, scrubs the latest export, reads in the original file, inserts original XML before the first element. That might take a bit of doing... will hold that until
the next version.

Additional 'scrubs' may be added; for example, the User table DBC export contains an array of 8-bit signed integers which can be converted back into the hex
string that the user table is expecting. If this gets added, the -NoScrub option will apply to both.

The 'Infile Directory' override is not supported at this time; I don't know what it does.

Normally I don't bother typing up this much documentation, but this may find its way to other Maximo customers so I figured I'd make it pretty. 
Created for funsies in October 2024 by Mike Hoeppner
#>
param(    
    [string]$MaximoHome = "c:\IBM\SMP\maximo",
    [switch]$NoScrub,
    [Parameter(ParameterSetName='Load')]    
    [string]$FromCSV,     
    [Parameter(Mandatory=$true,ParameterSetName='Adhoc')]
    [string]$Table,
    [Parameter(ParameterSetName='Adhoc')]
    [string]$Where,
    [Parameter(Mandatory=$true,ParameterSetName='Adhoc')]
    [string]$OutFile
)

#region Constants

$author = "A3JGroup"
$javaExePath = Join-Path -Path $MaximoHome -ChildPath "tools\java\jre\bin\java.exe"
$outPath = Join-Path -Path $MaximoHome -ChildPath "tools\maximo\en\script"
$toolRoot = Join-Path -Path $MaximoHome -ChildPath "tools\maximo"

$genInsertDBCArgs = "-classpath {0};{1}\classes;{2} psdi.tools.GenInsertDbc {3} {4}"

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
# Load data from the CSV file and iterate through it.
function Bulk-Export {
    param(
        $InputFile
    )

    #Convert file into array
    $rows = import-csv -Path $InputFile

    #Feed into the 'engine'
    foreach ($row in $rows) {
        Invoke-GenInsertDBC -dbcTable $row.Table -dbcOutfile $row.Outfile -dbcWhere $row.Where
    }
}

# Processes Maximo DBC files and scrubs out attributes with 'empty' values in 'columnvalue' nodes
function Scrub-DBC {
    param (
        $DBCFile
    )
    #Load DBC file
    [xml]$dbc = Get-Content -Path $DBCFile

    # Loop through each node to find null attributes
    foreach ($node in $dbc.SelectNodes("//columnvalue")) {
        #can't use foreach because IEnumerator objects are read-only
        for ($i = 0; $i -lt $node.Attributes.Count; $i++) {
            #If the attribute has an 'empty' value (not null) then remove that attribute by whatever name it has
			if ($node.Attributes[$i].Value -eq "" -or $node.Attributes.Count -eq 1 -and $node.Attributes["column"]) {
				
				$node.ParentNode.RemoveChild($node)
            }
        }
    }
	# Update the Author
    $dbc.documentElement.Author = $author

    # Dynamically set ScriptName based on file name
    $scriptName = [System.IO.Path]::GetFileNameWithoutExtension($DBCFile)
    $dbc.documentElement.ScriptName = $scriptName

    # Set Description based on ScriptName for context
    $dbc.documentElement.Description = "Script for table $scriptName - generated dynamically."

    # Remove empty "columnvalue" elements
    foreach ($node in $dbc.SelectNodes("//columnvalue")) {
        if ($node.Attributes["column"] -and $node.Attributes.Count -eq 1) {
            $node.ParentNode.RemoveChild($node)
        }
    }
	
    # Save the modified XML back to the file
    $file = Get-ChildItem -path $DBCFile -File
    $saveDBC = Join-Path -path $file.DirectoryName -ChildPath "$($file.BaseName)-scrubbed$($file.Extension)"
    $dbc.Save($saveDBC)
}

# Validate parameters and perform a single invocation of GenInsertDBC.jar
function Invoke-GenInsertDBC {
    param(
        $dbcTable,
        $dbcOutfile,
        $dbcWhere
    )

    #trim filename if someone put an extension on it. If you really want to create V1000_01.something.dbc, comment this line out.
    $dbcOutfileArg = "-f$([System.IO.Path]::GetFileNameWithoutExtension($dbcOutfile))"

    #prepend table argument
    $dbcTableArg = "-t$dbcTable"

    #format argument string; because the original use of %MAXIMO_CLASSPATH% didn't seem to work we're kludging it in
    $jArgs = ($genInsertDBCArgs -f $toolRoot,$toolRoot,$env:MAXIMO_CLASSPATH, $dbcTableArg,$dbcOutfileArg)

    #add Where clause to end of arguments if its present
    if (!([string]::IsNullOrEmpty($dbcWhere))) {
        #include double quotes
        $jArgs+= " -w""$dbcWhere"""
    }

    
    #args are prepped, time to execute. 

    #TODO: Theoretically we don't need to wait and it might be interesting to see if doing bulk exports would successfully allow for parallel child processes to execute.
    Start-Process -Wait -NoNewWindow -WorkingDirectory $toolRoot -FilePath $javaExePath -ArgumentList $jArgs

    #TODO: Not sure if we'd get error codes back from GenInsertDBC, could put error handling here.

    #Check to see ♪we don't want no scrub♫
    If (!($NoScrub.IsPresent)) {
        #infer filename
        $sourceFile = Join-Path -Path $outPath -ChildPath ("$([System.IO.Path]::GetFileNameWithoutExtension($dbcOutfile)).dbc")

        #validate file exists and run scrubbing
        if(Test-Path -Path $sourceFile -PathType Leaf) {
            Scrub-DBC -DBCFile $sourceFile
            #TODO: Additional scrub logic goes here
        }
        else {
            Write-Error "Could not confirm that $sourcefile exists; this could be caused by the GenInsertDBC.jar invocation failing and not being handled by this script."            
        }
    } #else we aren't scrubbing
}

#endregion

#main

#Make sure we can find JRE; it's a short trip otherwise
if(!(Test-Path -Path $javaExePath)) {
    write-error "Could not verify JRE available. Please check $javaExePath to make sure JRE is present."
    exit 1
}

#Set environment variables
Set-CommonEnv -MaximoHome $MaximoHome

#Determine if we're bulk-loading or doing an ad-hoc
if (!([string]::IsNullOrEmpty($FromCSV))) {
    if(Test-Path -Path $FromCSV) {
        Bulk-Export -InputFile $FromCSV
    }
    else {
        Write-Error "Could not verify the CSV file specified!"
        exit 1 #in case we're automating, return error code
    }
}
else {
    #okay, we're doing an ad-hoc DBC export. That parameter set is mandatory so we shouldn't have null values for Table or Outfile

    Invoke-GenInsertDBC -dbcTable $Table -dbcOutfile $OutFile -dbcWhere $Where
}

#end