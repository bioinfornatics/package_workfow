

declare -x needToBump=false
declare -x sourceUpdated=false
declare -x isInitialized=false
declare -x needSendSource=false
declare -x snapdate
declare -x revision
declare -x release
declare -x oldRPM
declare -x package_name
declare -x specFile
declare -x logDir
declare -x tmpSpecFile
declare -x logOut
declare -x logErr
declare -x originalDir
declare -x -a package_link=()
declare -x -a rpmsList=()
declare -x -a sourcesFiles=()


# die
# This function is used to raise an error
# Paramecters:
# - line number
# - message
die () {
    local parent_lineno message code
      parent_lineno="$1"
      message="$2"
      [[ -n $3 ]] && code="$3" || code=1
      if [[ -n "$message" ]] ; then
        echo "Error on or near line ${parent_lineno}: ${message}; exiting with status ${code}" >&2
      else
        echo "Error on or near line ${parent_lineno}; exiting with status ${code}" >&2
      fi
      [[ -z  "${originalDir}" ]] && originalDir=$( readlink -f . )
      cd "${originalDir}"
      end "${code}"
}


# init
# This function is used to initialized the workfow.
# Evry script need to start by this function
# Set log file for the given package
# Parameter:
# - package name
init () {
    [[ $# -eq 1 ]]          || die ${LINENO} 'init expected a one parameter to set package_name. Not '$# 1
    [[ -n "$1" ]]           || die ${LINENO} 'Package name should to be not empty' 1
    [[ -n "${branch}" ]]    || die ${LINENO} 'Branch name should to be not empty' 1
    [[ -n "${name}" ]]      || die ${LINENO} 'A real name to put into changelog is required' 1
    [[ -n "${mail}" ]]      || die ${LINENO} 'A mail to put into changelog is required' 1
    package_name="$1"
    trap 'die ${LINENO}' 1 15 ERR
    trap 'end' EXIT
    userstring="${name} <${mail}>"
    specFile="${SPECS}"'/'"${package_name}"'/'"${package_name}"'.spec'
    tmpSpecFile="${logDir}"'/'"${package_name}"'.spec'
    logOut="${logDir}"'/'"${package_name}_${branch}"'.out'
    logErr="${logDir}"'/'"${package_name}_${branch}"'.err'
    branchList=( $@ )
    originalDir=$( readlink -f . )
    
	if [[ ! -f "${specFile}" ]]; then
		pushd "${SPECS}"
			fedpkg clone "${package_name}"
		popd
	fi
    cp "${specFile}" "${tmpSpecFile}"

    [[ -d "${logDir}" ]]    || die ${LINENO} 'log directory: '${logDir}' do not exist' 1
    [[ -f "${specFile}" ]]  || die ${LINENO} 'spec file: '${specFile}' do not exist' 1
    [[ -f "${logOut}" ]]    && rm "${logOut}"
    [[ -f "${logErr}" ]]    && rm "${logErr}"
    isInitialized=true
    [[ -e /proc/$$/fd/3 ]] && die ${LINENO} 'File descriptor 3 already used' 1
    [[ -e /proc/$$/fd/4 ]] && die ${LINENO} 'File descriptor 4 already used' 1
    
    ${verbose} && echo 'Starting to process package '"${BOLD}${package_name}${RESET}"' on branch '"${BOLD}${branch}${RESET}"' ( '"${logDir}"' )'
    
    exec 3>&1  1>>"${logOut}" # Merqe fd 1 with fd 3 and Redirect to logOut file
    exec 4>&2  2>>"${logErr}" # Merqe fd 2 with fd 4 and Redirect to logErr file

    [[ ! -f "${specFile}" ]] && ( cd "${SPECS}" && fedpkg clone "${package_name}" )

    pushd "${SPECS}"/"${package_name}"/ 1> /dev/null
        fedpkg switch-branch ${branch} 1> /dev/null
        fedpkg pull 1> /dev/null
    popd  1> /dev/null
        
	getSourcesFiles
	sendNewSources
	if ${needSendSource}; then
		fedpkg new-sources ${sourcesFiles[@]}
        fedpkg commit -m 'Upload new sources' -p
    fi
}


# end
# This function is used to correctly quit the script
# You do not have need to call it as this function is called automatically when scrit exiting.
# Parameter:
# - exit code default 0
end (){
    local code
    [[ -n $1 ]] && code="$1" || code=0
    trap - EXIT
    trap - ERR
    [[ -e /proc/$$/fd/3 ]] && exec 1>&3 3>&- # Restore stdout Close file descriptor #3
    [[ -e /proc/$$/fd/4 ]] && exec 2>&4 4>&- # Restore stderr Close file descriptor #4
    cd "${originalDir}"
    exit "${code}"
}


# Check if a value exists in an array
# Parameter:
# - $1 item to search into given array  
# - $2 array  
# return  Success (0) if value exists, Failure (1) otherwise
inArray () {
    local item="$1"
    local array=( $2 )
    local exists=1
    local -i index=0
    while [[ $index -lt ${#array[@]} ]]; do
		if [[ ${array[$index]} == $item ]]; then
			index=${#array[@]}
			exists=0
		fi
		((index++))
    done
    return $exists
}


# bumpSpec
# This function is used to increase the release number
# You do not have need to call it as this function is called from localBuild and udpateSpec.
# Parameter:
# - comment to write into the spec file
bumpSpec () {
    local comment
    [[ $# -eq 1 ]] || die ${LINENO} "bumpSpec expected a comment" 1
    ${isInitialized} || die ${LINENO} "Error: you need to run init fuction at beginning" 1
    
    comment="$1"
    rpmdev-bumpspec -u "$userstring" --comment="${comment}" "${tmpSpecFile}"
}


# localBuild
# This function is used to do a local build
# The build is done if package get an update or if variable force is true
localBuild () {
    local fedora_version tmp srpms
    [[ $# -eq 0 ]] || die ${LINENO} 'buildRPM expected 0 or 1 parameters not '"$#" 1
    ${isInitialized} || die ${LINENO} 'Error: you need to run init fuction at beginning' 1
    
    ${verbose} && echo 'Building '"${package_name}"' rpms'
    
	if [[ "${branch}" == "master" ]]; then
		fedora_version='fedora-rawhide-'"$(uname -m)"
	else
		fedora_version="${branch/f/fedora-}"'-'"$(uname -m)"
	fi
    if ${needToBump} && ${force}; then
        bumpSpec "Rebuild" || die ${LINENO} 'bumpspec failure!' 1
    fi

    if ${needToBump} || ${force} ; then
        echo '==== Building '"${package_name}"' rpms ===='
        tmp=$( rpmbuild -bs "${tmpSpecFile}" )
        if [[ "${tmp}" =~ ${SRPMS}(.+\.rpm) ]]; then
            srpms="${SRPMS}${BASH_REMATCH[1]}"
            mock --resultdir="${logDir}" -r ${fedora_version} ${srpms} #|| die ${LINENO} 'mock failure!' 1
        else
            die ${LINENO} 'SRPMS : '"${tmp}"' was not found!' 1
        fi
        echo '==== End to build '"${package_name}"' rpms ===='
        
        downloadRPMS $(arch)
        getRPMS "${logDir}/build.log"
        rpmdiff "${oldRPM}" "${rpmsList[1]}"  >&2 && echo '==== No diff between rpms ====' || echo '==== Diff between rpms found ====' # at index 0 that the src.rpm
        echo 'Success'
    else
        echo 'No Update'
    fi
}


# remoteBuild
# This function is used to do a remote build by using fedpkg tool
# The build is done if package get an update or if variable force is true
# Parameter:
# - comment to use when commiting
remoteBuild () {
    local comment untracked item
    [[ "$#" -eq 0 || "$#" -eq 1 ]]  || die ${LINENO} "updatePackage expected 0 or 1 parameters not $#" 1
    [[ -n "$1" ]] && comment="$1" || comment='Rebuild'
    
    if ${needToBump} ; then
        pushd "${SPECS}"/"${package_name}"/  1> /dev/null
        
        ${verbose} && echo 'Updating package '${package_name}'from branch '${branch}
		
        cp "${tmpSpecFile}" "${specFile}"
        untracked=( $(git ls-files -o) )
        
        for item in "${untracked[@]}"; do
            if [[ $(basename "${specFile}") == "${item}" ]]; then
                git add "${item}"
            fi
        done
        
		getSourcesFiles
        
        fedpkg new-sources ${sourcesFiles[@]}
        
        fedpkg commit -m "${comment}" -p
        fedpkg build
        #bodhi -u $login -c "${comment}" -N "${comment}" --type='enhancement' ${package_name}
        popd  1> /dev/null
    else
        echo "${package_name}"' already up to date. Nothing to do.'
    fi
    
}


# build
# Thit function run localBuild and remoteBuild function
# Parameter:
# - comment to use when commiting
build () {
	local comment=''
	
    [[ "$#" -eq 0 || "$#" -eq 1 ]]  || die ${LINENO} "updatePackage expected 0 or 1 parameters not $#" 1
    [[ -n "$1" ]] && comment="$1"
    
    localBuild
    remoteBuild "${comment}"
	
}


# getLinkToRPMS
# This function return an url to rpm package and set package_link variable
# This allow to download it and by example use rpmdiff
getLinkToRPMS () {
    local line architecture
    ${isInitialized} 					|| die ${LINENO} 'Error: you need to run init fuction at beginning' 1
    [[ $# -eq 0 ||  $# -eq 1 ]]    		|| die ${LINENO} 'Error: getLinkToRPMS take 0 prameter or an architecture name as x86_64…' 1
    [[ $# -eq 1 ]] && architecture="$1" || architecture=''
    
    package_link=()
    
    while read line; do
        [[ "${line}" =~ ^ftp|http.+${package_name}.*\."${architecture}"\.rpm ]] && package_link+=("${line}")
        [[ "${line}" =~ ^ftp|http.+${package_name}.*\.noarch\.rpm ]] && package_link+=("${line}")
    done < <(yumdownloader --destdir=${logDir} --urls ${package_name})
    
    [[ ${#package_link[@]} -ne 0 ]] ||  die ${LINENO} 'Error: getLinkToRPMS fail to found url to download the rpm' 1
}


# downloadRPMS
# This function download rpm fron fedora repo and set oldRPM variable as path to this file
# downloadRPMS <arch>
downloadRPMS () {
    local architecture
    ${isInitialized}            			|| die ${LINENO} 'Error: you need to run init fuction at beginning' 1
    [[ $# -eq 1 ]]  && architecture="$1"    || die ${LINENO} 'Error: downloadRPMS take an architecture name as x86_64…' 1
    
    getLinkToRPMS "${architecture}"
    
    if [[ "${package_link[0]}" =~ .+(${package_name}.+\.rpm) ]]; then # assume is first index 0
        oldRPM="${logDir}/${BASH_REMATCH[1]}"
    else
        die ${LINENO} 'RPMS name not found into: '"${package_link[0]}" 1
    fi
    
    curl -s -o "${oldRPM}" "${package_link[0]}"
}


# getRPMS
# This function is not used.
# This function allow to get list of generated rpm file by reading log file
getRPMS () {
    local line buildLogFile
    ${isInitialized}        			|| die ${LINENO} 'Error: you need to run init fuction at beginning' 1
    [[ $# -eq 1 ]] && buildLogFile="$1" || die ${LINENO} 'Error: getRPMS expct the build log file as parameter' 1
    [[ -f "${buildLogFile}" ]]          || die ${LINENO} 'Error: The build log file do not exist: '"${buildLogFile}" 1
    
    for line in $(grep -o -e "${package_name}.*\.rpm" "${buildLogFile}"); do
        rpmsList+=("${logDir}/${line}")
    done
    
    [[ ${#rpmsList[@]} -ne 0 ]] || die ${LINENO} 'Error: generated file rpm are not found into log file: '"${buildLogFile}" 1
}


# getSpecRelease
# This function is not used
# This function allow to get the current release number from the spec file
getSpecRelease () {
    local isSearching eof
    local -r pattern='^Release:[[:blank:]]+([[:digit:]]+)'
    ${isInitialized}        			|| die ${LINENO} 'Error: you need to run init fuction at beginning' 1
    isSearching=true

    while isSearching; do
        eof=$(read line)

        if [[ "$eof" -ne 0 ]]; then
            isSearching=false
        elif [[ "${line}" =~ $pattern ]]; then
            isSearching=false
            release="${BASH_REMATCH[1]}"
        fi
    done  < "${tmpSpecFile}"
}


# udpateSpec
# This function is used to update spec file.
# Parameter:
# - comment to append into the changelog section
# - pairs of rules/new value to update into the spec file
#   The rule is a regexp with a group to catch.
#   If the regexp is true, it will replace the group caught by the given value.
#   If any rules is given that will force a build
udpateSpec () {
    local comment parameters index match line pattern value tmpfile
    [[ $# -ge 1 ]]                                  || die ${LINENO} 'udpadeSpec expected at least 1 parameters not '$# 1
    ${isInitialized}                    			|| die ${LINENO} 'Error: you need to run init fuction at beginning' 1
    [[ -n "$1" ]]                && comment="$1"    || die ${LINENO} 'udpadeSpec expected a comment as second parameter' 1
    shift
    
    ${verbose} && echo "Updating spec file: ${specFile}"

    if [[ -n "$@" ]]; then
        [[ $(( $# % 2 )) ]]  && parameters=( "$@" ) || die ${LINENO} 'udpadeSpec expected a paired numbers of parameters' 1

        tmpfile="$(mktemp)"

        while read -r line; do
            for (( index=0; $index < ${#parameters[@]}; index+=2 )); do 
                pattern=${parameters[$index]}
                value=${parameters[$(( $index + 1 ))]}

                if [[ -n "${line}" && "${line}" =~ ${pattern} && "${BASH_REMATCH[1]}" != "${value}" ]]; then
                    needToBump=true
                    line=${line/${BASH_REMATCH[1]}/${value}}
                fi
            done
            echo "${line}" >> "${tmpfile}"
        done < "${specFile}"
        
        ${needToBump} && mv "${tmpfile}" "${tmpSpecFile}"
    else
        needToBump=true
    fi
    
    if ${needToBump}; then
		bumpSpec "${comment}"
	fi
    
}


# getSourcesFiles
# This function is used to get sources files need by reading spec file.
# You do not have need to call it as this function is called by init function.
getSourcesFiles () {
    local line sourceFile url key hashValue varValue varname
    local -A variables
    
    while read line; do
        if [[ "${line}" =~ ^%global[[:blank:]]+([[:alnum:]_]+)[[:blank:]]+([[:alnum:][:punct:]]+) ]]; then
            varname='%{'"${BASH_REMATCH[1]}"'}'
            varValue="${BASH_REMATCH[2]}"
            if [[ "${varValue}" =~ [[:punct:]] ]]; then
                for key in "${!variables[@]}"; do
                        hashValue=${variables["${key}"]}
                    if [[ "${varValue}" =~ "${key}" ]]; then
                        varValue=${varValue//"${key}"/${hashValue}}
                    fi
                done
            fi
            variables["${varname}"]="${varValue}"
        elif [[ "${line}" =~ ^Name:[[:blank:]]+([[:alnum:][:punct:]]+) ]]; then
            variables['%{name}']="${BASH_REMATCH[1]}"
        elif [[ "${line}" =~ ^Version:[[:blank:]]+([[:digit:]\.]+) ]]; then
            variables['%{version}']="${BASH_REMATCH[1]}"
        elif [[ "${line}" =~ ^Patch|Source[[:digit:]]+:[[:blank:]]+([[:alnum:][:punct:]]+) ]]; then
            url="${BASH_REMATCH[1]}"
            
            if [[ "${url}" =~ ^http|ftp ]]; then
                sourceFile="${url##*/}"
            else
                sourceFile="${url}"
            fi
            
            for key in "${!variables[@]}"; do
                sourceFile=${sourceFile//"${key}"/${variables["${key}"]}}
            done
            
            sourcesFiles+=( "${SOURCES}"/"${sourceFile}" )  
        fi
    done < "${tmpSpecFile}"
    
    [[ ${#sourcesFiles[@]} -ne 0 ]] || die ${LINENO} 'sources files List is epmty' 1
}


# gitGetRepo
# This function is used to download a git repo and to update it from lates commit put by upstream
# Parameter:
# - git url to use
gitGetRepo () {
    local repo
    [[ "$#" -eq 1 ]]                || die ${LINENO} "gitGetRepo expected 1 parameters not $#" 1
    [[ -n "$1" ]]   && repo="$1"    || die ${LINENO} 'gitGetRepo expected a git url repository' 1
    ${isInitialized}        		|| die ${LINENO} "Error: you need to run init fuction at beginning" 1
    if [[ ! -d "${SOURCES}"/"${package_name}" ]]; then
        git clone "${repo}" "${SOURCES}"/"${package_name}" 1> /dev/null
        cd "${SOURCES}"/"${package_name}"
    else
        cd "${SOURCES}"/"${package_name}"
        git pull 1> /dev/null
    fi
}


# gitExtractSnapDate
# This function is used to get date from the latest commit.
# The date is stored into the global variable 'snapdate'.
gitExtractSnapDate () {
    local date_string
    [[ $# -eq 0 ]]  || die ${LINENO} "gitExtractSnapDate expected 0 parameters not $#" 1
    [[ -e '.git' ]] || die ${LINENO} "Error: is not a git repository" 1
    
    date_string=$(git log -1 --format="%ci")
    date_string="${date_string%% *}"
    snapdate="${date_string//-/}"
}


# gitExtractRev
# This function is used to get the latest revision.
# The revision is stored into the global variable 'revision'.
gitExtractRev () {
    [[ $# -eq 0 ]]          || die ${LINENO} "gitExtractRev expected 0 parameters not $#" 1
    [[ -e '.git' ]]         || die ${LINENO} "Error: is not a git repository" 1
    
    ${verbose} && echo "Extracting $(basename  $(pwd)) archive"
    revision="$(git rev-parse --short HEAD)"
}


# gitArchive
# This function is used to create an archive .tar.xz from a git repo.
# Parameter:
# - root directory to use
# - archive name
# - output dirctory
gitArchive () {
    local package alphatag outputDir archive
    [[ $# -eq 3 ]]  || die ${LINENO} "gitArchive expected 3 parameters not $#" 1
    [[ -e '.git' ]] || die ${LINENO} "Error: is not a git repository" 1
    
    prefix="$1"
    package="$2"
    outputDir="$3"
    archive=$( readlink -m "${outputDir}"/"${package}".tar.xz )
    [[ -f "${archive}" ]] || $(git archive --prefix="${prefix}"/ HEAD --format=tar | xz > "${archive}" )
}


# sendNewSources
# This furction parse sources file and compare to source dercribe into .spec file via sourcesFiles array
# if not equal needSendSource take false otherwise true
sendNewSources () {
	local needSendSource=false
	
	while read md5 file; do
		if ! inArray "${SOURCES}/${file}" ${sourcesFiles[@]} ; then
		    needSendSource=true
		    break
		fi
	done < "${SPECS}/${package_name}/sources"
}
