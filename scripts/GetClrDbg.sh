#! /bin/bash

script_dir=`dirname $0`

print_help()
{
    echo 'GetClrDbg.sh <version> [<install path>]'
    echo ''
    echo 'This script downloads and configures clrdbg, the Cross Platform .NET Debugger'
    echo 'If <install path> is not specified, clrdbg will be installed to the directory'
    echo 'from which this script was executed.' 
    echo '<version> can be "latest" or a version number such as 14.0.25109-preview-2865786'
}

# Sets __RuntimeID as given by 'dotnet --info'
get_dotnet_runtime_id()
{
    # example output of dotnet --info
    # .NET Command Line Tools (1.0.0-beta-002194)
    #
    # Product Information:
    #  Version:     1.0.0-beta-002194
    #  Commit Sha:  a28369bfe0
    #
    # Runtime Environment:
    #  OS Name:     ubuntu
    #  OS Version:  14.04
    #  OS Platform: Linux
    #  RID:         ubuntu.14.04-x64

    # Get the output of dotnet --info
    info="$(dotnet --info)"

    # filter to the line that contains the RID. Output still contains spaces. Example: '         ubuntu.14.04-x64'
    rid_line="$(echo "${info}" | awk 'BEGIN { FS=":" }{ if ( $1 ~ "RID" ) { print $2 } }')"

    # trim whitespace from awk return
    rid="$(echo -e "${rid_line}" | tr -d '[[:space:]]')"

    __RuntimeID=$rid
}

# Produces project.json in the current directory
# $1 is Runtime ID
generate_project_json()
{
    if [ -z $1 ]; then
        echo "Error: project.json cannot be produced without a Runtime ID being provided."
        exit 1
    fi

    echo "{"                                                                >  project.json
    echo "   \"dependencies\": {"                                           >> project.json
    echo "       \"Microsoft.VisualStudio.clrdbg\": \"$__ClrDbgVersion\""   >> project.json
    echo "   },"                                                            >> project.json
    echo "   \"frameworks\": {"                                             >> project.json
    echo "       \"netcoreapp1.0\": {"                                      >> project.json
    echo "          \"imports\": [ \"dnxcore50\", \"portable-net45+win8\" ]" >> project.json
    echo "       }"                                                         >> project.json
    echo "   },"                                                            >> project.json
    echo "   \"runtimes\": {"                                               >> project.json
    echo "      \"$1\": {}"                                                 >> project.json
    echo "   }"                                                             >> project.json
    echo "}"                                                                >> project.json
}

# Produces NuGet.config in the current directory
generate_nuget_config()
{
    echo "<?xml version=\"1.0\" encoding=\"utf-8\"?>"                                                           >  NuGet.config
    echo "<configuration>"                                                                                      >> NuGet.config
    echo "  <packageSources>"                                                                                   >> NuGet.config
    echo "      <clear />"                                                                                      >> NuGet.config
    echo "      <add key=\"api.nuget.org\" value=\"https://api.nuget.org/v3/index.json\" />"                    >> NuGet.config
    echo "  </packageSources>"                                                                                  >> NuGet.config
    echo "</configuration>"                                                                                     >> NuGet.config
}

is_project_json_supported()
{
    # Last preview2 release version is 3133 and starting preview3 only csproj files were supported.
    dotnetversion="$(dotnet --version)"
    v="$(echo $dotnetversion | awk -F'-'  '{print $3 + 0}')"
    if (("$v" <= 3133)); then
        return 0
    else
        return 1
    fi
}

if [ -z "$1" ]; then
    print_help
    exit 1
elif [ "$1" == "-h" ]; then
    print_help
    exit 1
fi

# This case statement is done on the lower case version of version_string
version_string="$(echo $1 | awk '{print tolower($0)}')"
case $version_string in
    latest)
        __ClrDbgVersion=15.0.25904-preview-3404276
        ;;
    vs2015u2)
        __ClrDbgVersion=15.0.25904-preview-3404276
        ;;
    *)
        simpleVersionRegex="^[0-9].*"
        if ! [[ "$1" =~ $simpleVersionRegex ]]; then
            echo "Error: '$1' does not look like a valid version number."
            exit 1
        fi
        __ClrDbgVersion=$1
        ;;
esac

echo "Info: Using clrdbg version '$__ClrDbgVersion'"

__InstallPath=$PWD
if [ ! -z "$2" ]; then
    if [ -f "$2" ]; then
        echo "Error: Path '$2' points to a regular file and not a directory"
        exit 1
    elif [ ! -d "$2" ]; then
        echo 'Info: Creating install directory'
        mkdir -p $2
        if [ "$?" -ne 0 ]; then
            echo "Error: Unable to create install directory: '$2'"
            exit 1
        fi
    fi
    __InstallPath=$2
fi

pushd $__InstallPath > /dev/null 2>&1
if [ "$?" -ne 0 ]; then
    echo "Error: Unable to cd to install directory '$__InstallPath'"
    exit 1
fi

# For the rest of this script we can assume the working directory is the install path

echo 'Info: Determinig Runtime ID'
__RuntimeID=
get_dotnet_runtime_id
if [ -z $__RuntimeID ]; then
    echo "Error: Unable to determine dotnet Runtime ID"
    echo "GetClrDbg.sh requires .NET CLI Tools version >= 1.0.0-beta-002173. Please make sure your install of .NET CLI is up to date"
    exit 1
fi
echo "Info: Using Runtime ID '$__RuntimeID'"

if is_project_json_supported; then
    # Legacy support till supported versions are available as zip.
    echo 'Info: Generating project.json'
    generate_project_json $rid

    echo 'Info: Generating NuGet.config'
    generate_nuget_config

    # dotnet restore and publish add color to their output
    # I have found that the extra characters to provide color can corrupt
    # the shell output when running this as part of docker build
    # Therefore, I redirect the output of these commands to a log
    echo 'Info: Executing dotnet restore'
    dotnet restore > dotnet_restore.log 2>&1
    if [ $? -ne 0 ]; then
        echo "dotnet restore failed"
        exit 1
    fi

    echo 'Info: Executing dotnet publish'
    dotnet publish -o . > dotnet_publish.log 2>&1
    if [ $? -ne 0 ]; then
        echo "dotnet publish failed"
        exit 1
    fi
else
    clrdbgZip="clrdbg.zip"
    target="$(echo ${__ClrDbgVersion}-${__RuntimeID} | tr '.' '-')"
    url="$(echo https://vsdebugger.azureedge.net/clrdbg-${target}/${clrdbgZip})"
   
    echo "Downloading ${url}"
    if ! hash unzip 2>/dev/null; then
        echo "unzip command not found. Install unzip for this script to work."
        exit 1
    fi
   
    if hash wget 2>/dev/null; then
        wget -q $url -O $clrdbgZip
    elif hash curl 2>/dev/null; then
        curl -s $url -o $clrdbgZip
    else
        echo "Install curl or wget. It is needed to download clrdbg."
        exit 1
    fi
    
    if [ $? -ne  0 ]; then
        echo "Could not download ${url}"
        exit 1;
    fi
    
    unzip -q $clrdbgZip
    
    if [ $? -ne  0 ]; then
        echo "Failed to unzip clrdbg"
        exit 1;
    fi
    
    chmod +x ./clrdbg
    rm $clrdbgZip
fi


popd > /dev/null 2>&1

echo "Successfully installed clrdbg at '$__InstallPath'"
exit 0
