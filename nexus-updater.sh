#!/usr/bin/env bash
#================================================================
# HEADER
#================================================================
#% SYNOPSIS
#+   ${SCRIPT_NAME} [-hv] 
#+   ${SCRIPT_NAME} [-d DIRECTORY] [-l FILE] [-f FILE] [APP[,APP]...]
#%
#% DESCRIPTION
#%   This script updates Nexus DR-X files and scripts.
#%
#% OPTIONS
#%    -h, --help              Print this help
#%    -v, --version           Print script information
#%    -l, --list              List of applications this script has the ability to
#%                            install.
#%    -s, --self-check        Scripts checks for a new version of itself when run and
#%                            automatically updates itself if an update is available.
#%    -f, --force-reinstall   Re-install an application even if it's up to date
#% 
#% COMMANDS 
#%    APP(s)                  Zero or more applications (comma separated) to install,
#%                            or udpate if already installed.
#%                            If no APPs are supplied, the script runs in GUI
#%                            mode and presents a user interface in which the user
#%                            can select one or more APPs for installation or
#%                            upgrade.
#%                                
#% EXAMPLES
#%    Run the script in GUI mode and run the self-checker:
#%
#%      ${SCRIPT_NAME} -s
#%
#%    Run the script from the command line and install or update fldigi and flmsg:
#%
#%      ${SCRIPT_NAME} fldigi,flmsg  
#%    
#%    Run the script from the command line and force a reinstall of fldigi and flmsg:
#%
#%      ${SCRIPT_NAME} -f fldigi,flmsg  
#%    
#================================================================
#- IMPLEMENTATION
#-    version         ${SCRIPT_NAME} 3.1.13
#-    author          Steve Magnuson, AG7GN
#-    license         CC-BY-SA Creative Commons License
#-    script_id       0
#-
#================================================================
#  HISTORY
#     20201120 : Steve Magnuson : Script creation
#     20211202 : Steve Magnuson : Migrate script to Bullseye OS
# 
#================================================================
#  DEBUG OPTION
#    set -n  # Uncomment to check your syntax, without execution.
#    set -x  # Uncomment to debug this shell script
#
#================================================================
# END_OF_HEADER
#================================================================

SYNTAX=false
DEBUG=false
Optnum=$#

#============================
#  FUNCTIONS
#============================

function TrapCleanup() {
  [[ -d "${TMPDIR}" ]] && rm -rf "${TMPDIR}/"
  exit 0
}


function SafeExit() {
  # Exit with arg1
  EXIT_CODE=${1:-0}
  #AdjustSwap  # Restore swap if needed
  # Delete temp files, if any
  [[ -d "${TMPDIR}" ]] && rm -rf "${TMPDIR}/"
  trap - INT TERM EXIT
  exit $EXIT_CODE
}


function ScriptInfo() { 
	HEAD_FILTER="^#-"
	[[ "$1" = "usage" ]] && HEAD_FILTER="^#+"
	[[ "$1" = "full" ]] && HEAD_FILTER="^#[%+]"
	[[ "$1" = "version" ]] && HEAD_FILTER="^#-"
	head -${SCRIPT_HEADSIZE:-99} ${0} | grep -e "${HEAD_FILTER}" | \
	sed -e "s/${HEAD_FILTER}//g" \
	    -e "s/\${SCRIPT_NAME}/${SCRIPT_NAME}/g" \
	    -e "s/\${SPEED}/${SPEED}/g" \
	    -e "s/\${DEFAULT_PORTSTRING}/${DEFAULT_PORTSTRING}/g"
}


function Usage() { 
	printf "Usage: "
	ScriptInfo usage
	SafeExit 0
}


function Die () {
	echo "${*}"
	SafeExit 1
}


function AptError () {
   echo
   echo
   echo
   echo >&2 "ERROR while running '$1'.  Exiting."
   echo
   echo
   echo
   SafeExit 1
}


function PiModel() {
   MODEL="$(egrep "^Model" /proc/cpuinfo | sed -e 's/ //;s/\t//g' | cut -d: -f2)"
   case $MODEL in
      "Raspberry Pi 2"*)
         echo "rpi2"
         ;;
      "Raspberry Pi 3"*)
         echo "rpi3"
         ;;
      "Raspberry Pi 4"*)
         echo "rpi4"
         ;;
      *)
         echo ""
         ;;
   esac
}


function getGoogleFile () {
   local RESULT=1
   local FILE_NAME="$1"
   local FILE_ID="$2"
   local BASE_URL="https://docs.google.com/uc?export=download"
   COOKIES="$TMPDIR/cookies.txt"
   WGET="$(command -v wget)"
   WGET_OPTIONS="--quiet --save-cookies $COOKIES --keep-session-cookies --no-check-certificate"
   CONFIRM="$($WGET $WGET_OPTIONS "${BASE_URL}&id=$FILE_ID" -O- | sed -rn 's/.*confirm=([0-9A-Za-z_]+).*/\1\n/p')&id=$FILE_ID"
   if (( $? == 0 ))
   then
      WGET_OPTIONS="--quiet --no-check-certificate --load-cookies $COOKIES"
      $WGET $WGET_OPTIONS "${BASE_URL}&confirm=$CONFIRM" -O "$FILE_NAME"
      (( $? == 0 )) && RESULT=0 || RESULT=1
   else
      RESULT=1
   fi
   rm -f $COOKIES
   return $RESULT
}


function LocalRepoUpdate() {

	# Checks if a local repository is set up and if not clones it. If there is a local
	# repo, then do a 'git pull' to see if there are updates. If no updates, return $FALSE 
	# otherwise return $TRUE.  
	#
	# arg1: Name of app to install/update
	# arg2: git URL for app
	
	UP_TO_DATE=$FALSE
	REQUEST="$1"
	URL="$2"
	REPO_NAME="$(echo "$URL" | cut -s -d' ' -f2)"
	if [[ -z $REPO_NAME ]]
	then
		GIT_DIR="$(echo ${URL##*/} | sed -e 's/\.git$//')"
	else
		GIT_DIR="$REPO_NAME"
	fi
	#cd $SRC_DIR
	echo "===== $REQUEST install/update requested ====="
	# See if local git repository exists. Create it ('git clone') if not
	if ! [[ -s $SRC_DIR/$GIT_DIR/.git/HEAD ]]
	then
		git -C $SRC_DIR clone $URL || { echo >&2 "===== git clone $URL failed ====="; SafeExit 1; }
	else  # See if local repo is up to date
		#cd $GIT_DIR
		git -C $SRC_DIR/$GIT_DIR reset --hard
		if git -C $SRC_DIR/$GIT_DIR pull | tee /dev/stderr | grep -q "^Already"
		then
			echo "===== $REQUEST up to date ====="
			UP_TO_DATE=$TRUE
		fi
	fi
	#cd $SRC_DIR
	[[ $UP_TO_DATE == $FALSE ]] && return $TRUE || return $FALSE
}


function NexusLocalRepoUpdate() {

	# Checks if a local Nexus repository is set up and if not clones it. If there 
	# is a local repo, then do a 'git pull' to see if there are updates. If no updates,
	# return $FALSE 
	# otherwise return $TRUE.  If there are updates, look for shell script named 
	# 'nexus-install' in repo and run it if present and executable.
	#
	# arg1: Name of app to install/update
	# arg2: git URL for app
	
	if (LocalRepoUpdate "$1" "$2") || [[ $FORCE == $TRUE ]]
	then
		cd $SRC_DIR
   	if [[ -x ${2##*/}/nexus-install ]]
   	then
   		${2##*/}/nexus-install || Die "Failed to install/update $1"
   	  	echo "===== $1 installed/updated ====="
			cd $SRC_DIR
      	return $TRUE
		fi
		return $TRUE
	else		
		cd $SRC_DIR
		return $FALSE
	fi
}


function CandidatePkgVersion() {

	# Checks the candidate version of a package
	# arg1: Name of package
	# Returns candidate version of package or empty string if package not found
	
	CANDIDATE_="$(apt-cache --no-generate policy "$1" 2>/dev/null | grep "Candidate:" | tr -d ' ' | cut -d: -f2)"
	[[ -z $CANDIDATE_ ]] && echo "" || echo "$CANDIDATE_"
	
}

function InstalledPkgVersion() {

	# Checks if a deb package is installed and returns version if it is
	# arg1: Name of package
	# Returns version of installed package or empty string if package is
	# not installed
	
	local INSTALLED_="$(dpkg -l "$1" 2>/dev/null | grep "$1" | tr -s ' ')"
	[[ $INSTALLED_ =~ ^[hi]i ]] && echo "$INSTALLED_" | cut -d ' ' -f3 || echo ""
}


function DebPkgVersion() {
	# Checks the version of a .deb package file.
	# Returns version of the .deb package or empty string if .deb file can't be read
	# arg1: path to .deb file
	VERSION_="$(dpkg-deb -I "$1" 2>/dev/null | grep "^ Version:" | tr -d ' ' | cut -d: -f2)"
	[[ -z $VERSION_ ]] && echo "" || echo "$VERSION_"

}


function CheckDepInstalled() {
	# Checks the installation status of a list of packages. Installs them if they are not
	# installed.
	# Takes 1 argument: a string containing the apps to check with apps separated by space
	#MISSING=$(dpkg --get-selections $1 2>&1 | grep -v 'install$' | awk '{ print $6 }')
	#MISSING=$(dpkg-query -W -f='${Package} ${Status}\n' $1 2>&1 | grep 'not-installed$' | awk '{ print $1 }')
	echo >&2 "Checking dependencies..."
	MISSING=""
   for P in $1
   do
      if apt-cache --no-generate policy $P 2>/dev/null | grep -q "Installed: (none)"
      then
         MISSING+="$P "
      fi
   done
	if [[ ! -z $MISSING ]]
	then
		sudo apt-get -y install $MISSING || AptError "$MISSING"
		[[ $MISSING =~ aptitude ]] && sudo aptitude update
	fi
	echo >&2 "Done."
}

#function InstallPiardop() {
# 	declare -A ARDOP
# 	ARDOP[1]="$PIARDOP_URL"
# 	ARDOP[2]="$PIARDOP2_URL"
#   	cd $HOME
# 	for V in "${!ARDOP[@]}"
# 	do
#    	echo "=========== Installing piardop version $V ==========="
#    	PIARDOP_BIN="${ARDOP[$V]##*/}"
#    	echo "=========== Downloading ${ARDOP[$V]} ==========="
#    	wget -q -O $PIARDOP_BIN "${ARDOP[$V]}" || { echo >&2 "======= ${ARDOP[$V]} download failed with $? ========"; SafeExit 1; }
#    	chmod +x $PIARDOP_BIN
#    	sudo mv $PIARDOP_BIN /usr/local/bin/
#	    cat >> $HOME/.asoundrc << EOF
#pcm.ARDOP {
#type rate
#slave {
#pcm "plughw:1,0"
#rate 48000
#}
#}
#EOF
#    	echo "=========== piardop version $V installed  ==========="
#    done
#}


function CheckInternet() {
	# Check for Internet connectivity
	if ! ping -q -w 1 -c 1 github.com > /dev/null 2>&1
	then
		if [[ $GUI == $TRUE ]]
		then
   		yad --center --title="$TITLE" --info --borders=30 \
      		 --text="<b>No Internet connection found.  Check your Internet connection \
and run this script again.</b>" --buttons-layout=center \
	      	 --button=Close:0
	   else
	   	echo >&2 "No Internet connection found.  Check your Internet connection \
and run this script again."
	   fi
   	SafeExit 1
	fi

}


function GenerateList () {
	# Creates a list of apps used for use in yad selection window
	# Takes 1 argument:  0 = Pick boxes for installed apps are not checked, 1 = Pick boxes for installed apps are checked.
	# yad uses pango markup to format text: https://docs.gtk.org/Pango/pango_markup.html
	TFILE="$(mktemp)"
	declare -a CHECKED
	CHECKED[0]="FALSE"
	CHECKED[1]="TRUE"
	WARN_OPEN="<span color='red'><b>"
	WARN_CLOSE="</b></span>"

	for A in $LIST 
	do
		if echo "$SUSPENDED_APPS" | grep -qx "$A"
		then
			# App has been suspended. Apply special formatting.
			echo -e "FALSE\n${WARN_OPEN}<s>$A</s>${WARN_CLOSE}\n${WARN_OPEN}<s>${DESC[$A]}</s>${WARN_CLOSE}\n${WARN_OPEN}SUSPENDED pending bug fixes${WARN_CLOSE}" >> "$TFILE"
		else
			case $A in
				autohotspot|raspbian)
					echo -e "${CHECKED[$1]}\n$A\n${DESC[$A]}\nInstalled - Check for Updates" >> "$TFILE" 
					;;
				chirp)
					if command -v chirp 1>/dev/null 2>&1
					then
						echo -e "${CHECKED[$1]}\n$A\n${DESC[$A]}\nInstalled - Check for Updates" >> "$TFILE" 
					else
						echo -e "FALSE\n$A\n${DESC[$A]}\nNew Install" >> "$TFILE"
					fi
					;;
				hamlib)
					if command -v rigctl 1>/dev/null 2>&1
					then
						echo -e "${CHECKED[$1]}\n$A\n${DESC[$A]}\nInstalled - Check for Updates" >> "$TFILE" 
					else
						echo -e "FALSE\n$A\n${DESC[$A]}\nNew Install" >> "$TFILE"
					fi
					;;
				nexus-audio)
					echo -e "${CHECKED[$1]}\n$A\n${DESC[$A]}\nInstalled - Check for Updates" >> "$TFILE" 
					;;
				nexus-utils)
					if command -v initialize-pi.sh 1>/dev/null 2>&1
					then
						echo -e "${CHECKED[$1]}\n$A\n${DESC[$A]}\nInstalled - Check for Updates" >> "$TFILE" 
					else
						echo -e "FALSE\n$A\n${DESC[$A]}\nNew Install" >> "$TFILE"
					fi
					;;
				direwolf-utils)
					if command -v dw_pat_gui.sh 1>/dev/null 2>&1
					then
						echo -e "${CHECKED[$1]}\n$A\n${DESC[$A]}\nInstalled - Check for Updates" >> "$TFILE" 
					else
						echo -e "FALSE\n$A\n${DESC[$A]}\nNew Install" >> "$TFILE"
					fi
					;;
				rigctl-utils)
					if command -v rigctl_gui.sh 1>/dev/null 2>&1
					then
						echo -e "${CHECKED[$1]}\n$A\n${DESC[$A]}\nInstalled - Check for Updates" >> "$TFILE" 
					else
						echo -e "FALSE\n$A\n${DESC[$A]}\nNew Install" >> "$TFILE"
					fi
					;;
				rmsgw)
					if command -v rmsgw_aci 1>/dev/null 2>&1
					then
						echo -e "${CHECKED[$1]}\n$A\n${DESC[$A]}\nInstalled - Check for Updates" >> "$TFILE" 
					else
						echo -e "FALSE\n$A\n${DESC[$A]}\nNew Install" >> "$TFILE"
					fi
					;;
				nexus-update)
					echo -e "FALSE\n$A\n${DESC[$A]}\nUpdated Automatically" >> "$TFILE"
					;;
				piardop)
					if command -v piardopc 1>/dev/null 2>&1 
					then
						echo -e "${CHECKED[$1]}\n$A\n${DESC[$A]}\nInstalled - Check for Updates" >> "$TFILE"
					else
						echo -e "FALSE\n$A\n${DESC[$A]}\nNew Install" >> "$TFILE"
					fi		
					;;
				linbpq)
					if [[ -x $HOME/linbpq/linbpq ]]
					then
						echo -e "${CHECKED[$1]}\n$A\n${DESC[$A]}\nInstalled - Check for Updates" >> "$TFILE"
					else
						echo -e "FALSE\n$A\n${DESC[$A]}\nNew Install" >> "$TFILE"
					fi		
					;;
				710)
					if command -v 710.sh 1>/dev/null 2>&1 
					then
						echo -e "${CHECKED[$1]}\n$A\n${DESC[$A]}\nInstalled - Check for Updates" >> "$TFILE"
					else
						echo -e "FALSE\n$A\n${DESC[$A]}\nNew Install" >> "$TFILE"
					fi
					;;
				nexus-backup-restore)
					if command -v nexus-backup-restore.sh 1>/dev/null 2>&1 
					then
						echo -e "${CHECKED[$1]}\n$A\n${DESC[$A]}\nInstalled - Check for Updates" >> "$TFILE"
					else
						echo -e "FALSE\n$A\n${DESC[$A]}\nNew Install" >> "$TFILE"
					fi
					;;
				yaac)
					if [[ -s /usr/local/share/applications/YAAC.desktop ]]
					then
						echo -e "${CHECKED[$1]}\n$A\n${DESC[$A]}\nInstalled - Check for Updates" >> "$TFILE"
					else
						echo -e "FALSE\n$A\n${DESC[$A]}\nNew Install" >> "$TFILE"
					fi
					;;    
				cqrlog)
					if [[ -s $HOME/cqrlog/usr/bin/cqrlog ]]
					then
						echo -e "${CHECKED[$1]}\n$A\n${DESC[$A]}\nInstalled - Check for Updates" >> "$TFILE"
					else
						echo -e "FALSE\n$A\n${DESC[$A]}\nNew Install" >> "$TFILE"
					fi
					;;
				smart-heard)
					if [[ -s $HOME/WB7FHC/smart_heard.sh ]]
					then
						echo -e "${CHECKED[$1]}\n$A\n${DESC[$A]}\nInstalled - Check for Updates" >> "$TFILE"
					else
						echo -e "FALSE\n$A\n${DESC[$A]}\nNew Install" >> "$TFILE"
					fi
					;;
				*)
					#if command -v $A 1>/dev/null 2>&1 
					if [[ -n $(InstalledPkgVersion $A) ]]
					then
						echo -e "${CHECKED[$1]}\n$A\n${DESC[$A]}\nInstalled - Check for Updates" >> "$TFILE"
					else
						echo -e "FALSE\n$A\n${DESC[$A]}\nNew Install" >> "$TFILE"
					fi
					;;
			esac
		fi
	done
}


function GenerateTable () {
	# Takes 1 argument:  The first word of the middle button ("Select" or "Unselect")

	ANS="$(yad --center --title="$TITLE" --list --borders=10 \
		--height=600 --width=900 --text-align=center \
		--text "<b>This script will install and/or check for and install updates for the apps you select below.\n \
If there are updates available, it will install them.</b>\n\n \
<b><span color='blue'>For information about or help with an app, double-click the app's name.</span></b>\n \
This will open the Pi's web browser.\n \
This Pi must be connected to the Internet for this script to work.\n\n \
<b><span color='red'>CLOSE ALL OTHER APPS</span></b> <u>before</u> you click OK.\n" \
--separator="|" --checklist --grid-lines=hor \
--dclick-action="bash -c \"Help %s\"" \
--auto-kill --column 'Install/Update' --column Applications --column Description \
--column Action < "$TFILE" --buttons-layout=center --button='<b>Cancel</b>':1 \
--button="<b>$1 All Installed</b>":2 --button='<b>OK</b>':0)"
	return $?

}

function Help () {
	declare -A APPS
	APPS[fldigi]="http://www.w1hkj.com/FldigiHelp"
	APPS[flmsg]="http://www.w1hkj.com/flmsg-help"
	APPS[flamp]="http://www.w1hkj.com/flamp-help"
	APPS[flrig]="http://www.w1hkj.com/flrig-help"
	APPS[flwrap]="http://www.w1hkj.com/flwrap-help"
	APPS[direwolf]="https://github.com/wb2osz/direwolf"
	APPS[pat]="https://getpat.io/"
	APPS[arim]="https://www.whitemesa.net/arim/arim.html"
	APPS[ardop]="https://www.cantab.net/users/john.wiseman/Documents/ARDOPC.html"
	#APPS[chirp]="https://chirp.danplanet.com/projects/chirp/wiki/Home"
	APPS[wsjtx]="https://physics.princeton.edu/pulsar/K1JT/wsjtx.html"
	APPS[xastir]="http://xastir.org/index.php/Main_Page"
	APPS[nexus-backup-restore]="https://github.com/AG7GN/nexus-backup-restore/blob/master/README.md"
	APPS[nexus-audio]="${NEXUSDRX_GIT_URL}/nexus-audio/blob/main/README.md"
	APPS[nexus-utils]="${NEXUSDRX_GIT_URL}/nexus-utils/blob/main/README.md"
	APPS[direwolf-utils]="${NEXUSDRX_GIT_URL}/direwolf-utils/blob/main/README.md"
	APPS[rigctl-utils]="${NEXUSDRX_GIT_URL}/rigctl-utils/blob/main/README.md"
	APPS[smart-heard]="${NEXUSDRX_GIT_URL}/smart-heard/blob/main/README.md"
	APPS[autohotspot]="https://github.com/AG7GN/autohotspot/blob/master/README.md"
	APPS[710]="https://github.com/AG7GN/kenwood/blob/master/README.md"
	APPS[rmsgw]="${NEXUSDRX_GIT_URL}/package-staging/blob/main/rmsgw/README.md"
	APPS[js8call]="http://js8call.com"
	APPS[linbpq]="http://www.cantab.net/users/john.wiseman/Documents/InstallingLINBPQ.html"
	APPS[linpac]="https://sourceforge.net/projects/linpac/"
	APPS[hamlib]="https://github.com/Hamlib/Hamlib"
	APPS[uronode]="https://www.mankier.com/8/uronode"
	APPS[yaac]="https://www.ka2ddo.org/ka2ddo/YAAC.html"
	APPS[qsstv]="http://users.telenet.be/on4qz/index.html"
	APPS[cqrlog]="https://www.cqrlog.com"
	APPS[gpredict]="http://gpredict.oz9aec.net/index.php"
	APPS[wfview]="https://wfview.org/"
	APPS[fllog]="http://www.w1hkj.com/fllog-help/"
	APPS[flcluster]="http://www.w1hkj.com/flcluster-help/"
	APPS[arim]="https://www.whitemesa.net/arim/arim.html"
	APPS[garim]="https://www.whitemesa.net/arim/arim.html"
	APPS[libax25]="https://github.com/ve7fet/linuxax25"
	APP="$2"
	xdg-open ${APPS[$APP]} 2>/dev/null &
}
export -f Help

function InstallLibax25 () {
	# Force-installs libax25 due to longstanding conflict with header file in
	# libc6.
	# Returns 0 if successful, 1 if not.
	local RESULT=0
	pushd . >/dev/null
	cd $HOME
	if apt download libax25
	then
		sudo dpkg -i --force-overwrite $HOME/libax25_*${PKG_TYPE}
		RESULT=$?
		rm -f $HOME/libax25_*${PKG_TYPE}
	else
		RESULT=1
	fi
	popd >/dev/null
	return $RESULT
}

#============================
#  FILES AND VARIABLES
#============================

# Set Temp Directory
# -----------------------------------
# Create temp directory with three random numbers and the process ID
# in the name.  This directory is removed automatically at exit.
# -----------------------------------
TMPDIR="/tmp/${SCRIPT_NAME}.$RANDOM.$RANDOM.$RANDOM.$$"
(umask 077 && mkdir "${TMPDIR}") || {
  Die "Could not create temporary directory! Exiting."
}

  #== general variables ==#
SCRIPT_NAME="$(basename ${0})" # scriptname without path
SCRIPT_DIR="$( cd $(dirname "$0") && pwd )" # script directory
SCRIPT_FULLPATH="${SCRIPT_DIR}/${SCRIPT_NAME}"
SCRIPT_ID="$(ScriptInfo | grep script_id | tr -s ' ' | cut -d' ' -f3)"
SCRIPT_HEADSIZE=$(grep -sn "^# END_OF_HEADER" ${0} | head -1 | cut -f1 -d:)
VERSION="$(ScriptInfo version | grep version | tr -s ' ' | cut -d' ' -f 4)" 

GITHUB_URL="https://github.com"
NEXUSDRX_GIT_URL="$GITHUB_URL/NexusDR-X"
ARIM_URL="https://www.whitemesa.net/arim/arim.html"
GARIM_URL="https://www.whitemesa.net/garim/garim.html"
PIARDOP_URL="http://www.cantab.net/users/john.wiseman/Downloads/Beta/piardopc"
#PIARDOP2_URL="http://www.cantab.net/users/john.wiseman/Downloads/Beta/piardop2"
#CHIRP_URL="https://trac.chirp.danplanet.com/chirp_daily/LATEST"
CHIRP_URL="$GITHUB_URL/goldstar611/chirp-appimage/releases/latest"
CHIRP_ICO="$GITHUB_URL/goldstar611/chirp/raw/master/share/chirp.png"
CHIRP_DESKTOP="https://raw.githubusercontent.com/goldstar611/chirp/master/share/chirp.desktop"
CHIRPNEXT_URL="https://trac.chirp.danplanet.com/download?stream=next"
NEXUS_UPDATE_GIT_URL="${NEXUSDRX_GIT_URL}/nexus-update"
NEXUS_UTILS_GIT_URL="${NEXUSDRX_GIT_URL}/nexus-utils"
NEXUS_AUDIO_GIT_URL="${NEXUSDRX_GIT_URL}/nexus-audio"
CHIRP_GIT_URL="${NEXUSDRX_GIT_URL}/chirp"
DIREWOLF_UTILS_GIT_URL="${NEXUSDRX_GIT_URL}/direwolf-utils"
RIGCTL_UTILS_GIT_URL="${NEXUSDRX_GIT_URL}/rigctl-utils"
SMARTHEARD_GIT_URL="${NEXUSDRX_GIT_URL}/smart-heard"
AUTOHOTSPOT_GIT_URL="$GITHUB_URL/AG7GN/autohotspot"
KENWOOD_GIT_URL="$GITHUB_URL/AG7GN/kenwood"
NEXUS_BU_RS_GIT_URL="$GITHUB_URL/AG7GN/nexus-backup-restore"
NEXUS_RMSGW_GIT_URL="$GITHUB_URL/AG7GN/nexus-rmsgw"
LINBPQ_URL="http://www.cantab.net/users/john.wiseman/Downloads/Beta/pilinbpq"
LINBPQ_DOC="http://www.cantab.net/users/john.wiseman/Downloads/Beta/HTMLPages.zip"
YAAC_URL="https://www.ka2ddo.org/ka2ddo/YAAC.zip"
CQRLOG_GIT_URL="$GITHUB_URL/ok2cqr/cqrlog.git"
GPREDICT_GIT_URL="$GITHUB_URL/csete/gpredict.git"
REBOOT="NO"
#SRC_DIR="/usr/local/src/nexus"
#SHARE_DIR="/usr/local/share/nexus"
TITLE="Nexus Updater - version $VERSION"

declare -r TRUE=0
declare -r FALSE=1
SELF_UPDATE=$FALSE
GUI=$FALSE
FORCE=$FALSE
FLDIGI_DEPS_INSTALLED=$FALSE
SWAP_FILE="/etc/dphys-swapfile"
SWAP="$(grep "^CONF_SWAPSIZE" $SWAP_FILE | cut -d= -f2)"

declare -A DESC
DESC[raspbian]="Raspbian OS and Apps"
DESC[710]="Rig Control Scripts for Kenwood 710/71A"
#DESC[ardop]="Digital Open Protocol Modem versions 1 and 2"
DESC[arim]="Amateur Radio Instant Messaging"
DESC[garim]="Amateur Radio Instant Messaging GUI"
DESC[autohotspot]="Wireless HotSpot on your Pi"
DESC[chirp]="Radio Programming Tool"
DESC[direwolf]="Packet Modem/TNC and APRS Encoder/Decoder"
DESC[direwolf-utils]="Scripts and GUIs for Direwolf"
DESC[flamp]="Amateur Multicast Protocol tool for Fldigi"
DESC[flcluster]="Display DX Cluster data"
DESC[fldigi]="Fast Light DIGItal Modem"
DESC[fllog]="QSO Logging Server"
DESC[flmsg]="Forms Manager for Fldigi"
DESC[flrig]="Rig Control for Fldigi"
DESC[flwrap]="File Encapsulation for Fldigi"
DESC[gpredict]="Real time satellite tracking"
DESC[hamlib]="libhamlib4,libhamlib-utils,libhamlib-dev"
DESC[js8call]="Weak signal messaging using JS8"
DESC[libax25]="VE7FET's libax25, ax25-apps, ax25-tools"
DESC[linbpq]="G8BPQ AX25 Networking Package"
DESC[linpac]="AX.25 keyboard to keyboard chat and PBBS"
DESC[nexus-audio]="PulseAudio configuration for Fe-Pi"
DESC[nexus-backup-restore]="Nexus Backup/Restore scripts"
#DESC[nexus-iptables]="Firewall Rules for Nexus Image"
DESC[nexus-rmsgw]="RMS Gateway software for the Nexus Image"
DESC[nexus-update]="This Updater script"
DESC[nexus-utils]="Scripts and Apps for Nexus Image"
DESC[pat]="Winlink email client"
DESC[piardop]="G8BPQ ARDOP Modem"
DESC[putty]="SSH, Telnet and serial console"
DESC[qsstv]="Receiving and transmitting SSTV/DSSTV"
DESC[rigctl-utils]="Scripts and GUIs for rigctl"
DESC[rmsgw]="Winlink RMS Gateway for Linux"
DESC[smart-heard]="WB7FHC's FSQ Heard Logger"
DESC[uronode]="Node front end for AX.25, NET/ROM, Rose, TCP"
DESC[wfview]="ICOM rig control and spectrum display"
DESC[wsjtx]="Weak Signal Modes Modem"
DESC[xastir]="APRS Tracking and Mapping Utility"
DESC[yaac]="Yet Another APRS Client"

MAINTAINER="ag7gn@arrl.net"

# Determine OS
# The following line gets VERSION_CODENAME
eval $(cat /etc/*-release | grep -E '^VERSION_CODENAME')
if [[ ${VERSION_CODENAME^^} != "BULLSEYE" ]]
then
	echo >&2 -e "\033[1;33;41;5mERROR! ERROR! ERROR! \033[0m\033[1;33m This script will only run with RaspiOS \"Bullseye\" OS! \033[0m"
	Die "${SCRIPT_NAME}: Wrong OS"
fi

# Determine package type based on 32 or 64 bit OS
if (( $(getconf LONG_BIT) == 64 ))
then
	PKG_TYPE="arm64.deb"
	LIST="raspbian 710 arim autohotspot chirp direwolf direwolf-utils flamp flcluster fldigi fllog flmsg flrig flwrap garim gpredict hamlib js8call libax25 linpac nexus-audio nexus-backup-restore nexus-update nexus-utils pat qsstv rigctl-utils rmsgw smart-heard uronode wfview wsjtx yaac xastir"
else
	PKG_TYPE="armhf.deb"
	LIST="raspbian 710 arim autohotspot chirp direwolf direwolf-utils flamp flcluster fldigi fllog flmsg flrig flwrap garim gpredict hamlib js8call libax25 linbpq linpac nexus-audio nexus-backup-restore nexus-update nexus-utils pat piardop qsstv rigctl-utils rmsgw smart-heard uronode wfview wsjtx yaac xastir"
fi

# Add apps to temporarily disable from install/update process in this variable. Set to
# empty string if there are none. Put each entry on it's own line.
# Example: SUSPENDED_APPS="fldigi
#flrig"
SUSPENDED_APPS=""

#============================
#  PARSE OPTIONS WITH GETOPTS
#============================

#== set short options ==#
SCRIPT_OPTS='fslhv-:'

#== set long options associated with short one ==#
typeset -A ARRAY_OPTS
ARRAY_OPTS=(
	[help]=h
	[version]=v
	[dir]=d
	[file]=f
	[log]=l
)

LONG_OPTS="^($(echo "${!ARRAY_OPTS[@]}" | tr ' ' '|'))="

# Parse options
while getopts ${SCRIPT_OPTS} OPTION
do
	# Translate long options to short
	if [[ "x$OPTION" == "x-" ]]
	then
		LONG_OPTION=$OPTARG
		LONG_OPTARG=$(echo $LONG_OPTION | egrep "$LONG_OPTS" | cut -d'=' -f2-)
		LONG_OPTIND=-1
		[[ "x$LONG_OPTARG" = "x" ]] && LONG_OPTIND=$OPTIND || LONG_OPTION=$(echo $OPTARG | cut -d'=' -f1)
		[[ $LONG_OPTIND -ne -1 ]] && eval LONG_OPTARG="\$$LONG_OPTIND"
		OPTION=${ARRAY_OPTS[$LONG_OPTION]}
		[[ "x$OPTION" = "x" ]] &&  OPTION="?" OPTARG="-$LONG_OPTION"
		
		if [[ $( echo "${SCRIPT_OPTS}" | grep -c "${OPTION}:" ) -eq 1 ]]; then
			if [[ "x${LONG_OPTARG}" = "x" ]] || [[ "${LONG_OPTARG}" = -* ]]; then 
				OPTION=":" OPTARG="-$LONG_OPTION"
			else
				OPTARG="$LONG_OPTARG";
				if [[ $LONG_OPTIND -ne -1 ]]; then
					[[ $OPTIND -le $Optnum ]] && OPTIND=$(( $OPTIND+1 ))
					shift $OPTIND
					OPTIND=1
				fi
			fi
		fi
	fi

	# Options followed by another option instead of argument
	if [[ "x${OPTION}" != "x:" ]] && [[ "x${OPTION}" != "x?" ]] && [[ "${OPTARG}" = -* ]]
	then 
		OPTARG="$OPTION" OPTION=":"
	fi

	# Finally, manage options
	case "$OPTION" in
		h) 
			ScriptInfo full
			SafeExit 0
			;;
		v) 
			ScriptInfo version
			SafeExit 0
			;;
		f)
			FORCE=$TRUE
			;;
		s)
			SELF_UPDATE=$TRUE
			;;
		l)
			echo >&2
			echo "This script can install/update these applications:"
			echo >&2
			KEYS=( $( echo ${!DESC[@]} | tr ' ' $'\n' | sort ) )
			for I in "${KEYS[@]}"
			do
				printf "%20s: %s\n" "${I}" "${DESC[$I]}"
			done
			echo >&2
			SafeExit 0
			;;
		:) 
			Die "${SCRIPT_NAME}: -$OPTARG: option requires an argument"
			;;
		?) 
			Die "${SCRIPT_NAME}: -$OPTARG: unknown option"
			;;
	esac
done
shift $((${OPTIND} - 1)) ## shift options

#export click_pat_help_cmd='bash -c "xdg-open /usr/local/share/nexus/pat_help.html"'


#============================
#  MAIN SCRIPT
#============================

# Trap bad exits with cleanup function
trap SafeExit EXIT INT TERM

# Exit on error. Append '||true' when you run the script if you expect an error.
#set -o errexit

# Check Syntax if set
$SYNTAX && set -n
# Run in debug mode, if set
$DEBUG && set -x 

if [[ -z $SRC_DIR ]]
then
	SCRIPT_VARS_FILE="/${TMPDIR}/env.vars"
	echo "SRC_DIR=/usr/local/src/nexus" > $SCRIPT_VARS_FILE
	echo "SHARE_DIR=/usr/local/share/nexus" >> $SCRIPT_VARS_FILE
	echo "NEXUSDRX_GIT_URL=$NEXUSDRX_GIT_URL" >> $SCRIPT_VARS_FILE
	export $(cat $SCRIPT_VARS_FILE)
	#echo "SRC_DIR and SHARE_DIR exported."
fi

(( $# == 0 )) && test $DISPLAY && GUI=$TRUE || GUI=$FALSE

CheckInternet

if [[ $SELF_UPDATE == $TRUE ]] && (LocalRepoUpdate nexus-update "$NEXUS_UPDATE_GIT_URL")
then
	pushd . >/dev/null
	cd $SRC_DIR
   if [[ -x nexus-update/nexus-install ]]
   then
   	nexus-update/nexus-install || Die "Failed to install/update nexus-update"
     	echo "===== nexus-update installed/updated ====="
	fi
	popd >/dev/null
	if [[ $GUI == $TRUE ]]
	then
		yad --center --title="$TITLE" --info --borders=30 \
		--no-wrap --text="A new version of the Nexus Updater has been installed.\n\nPlease \
run <b>Raspberry > Hamradio > Nexus Updater</b> again." \
		--buttons-layout=center \
		--button=Close:0
  		SafeExit 0
  	else
  		echo >&2
  		echo >&2 "A new version of this script has been installed. Please run it again."
  		echo >&2
  		SafeExit 0
  	fi
fi

#-----------------------------------------------------------------------------------------
# Make nexus source and share folders if necessary
for D in $SRC_DIR $SHARE_DIR
do
	if [[ ! -d $D ]]
	then
		sudo mkdir -p $D
		sudo chown $USER:$USER $D
	fi	
	# Make sure ownership is $USER
	if [[ $(stat -c '%U:%G' $D) != "$USER:$USER" ]]
	then
		sudo chown -R $USER:$USER $D
	fi	
done

#-----------------------------------------------------------------------------------------
# Make sure source code URIs are enabled
sudo sed -i 's/^#deb-src/deb-src/' /etc/apt/sources.list
sudo sed -i 's/^#deb-src/deb-src/' /etc/apt/sources.list.d/raspi.list

#-----------------------------------------------------------------------------------------
# Check age of apt cache. Run apt update if more than 2 hours old
LAST_APT_UPDATE=$(stat -c %Z /var/lib/apt/lists/partial)
NOW=$(date +%s)
[[ -z $LAST_APT_UPDATE ]] && LAST_APT_UPDATE=0
if (( $( expr $NOW - $LAST_APT_UPDATE ) > 7200 ))
then
	echo >&2 "Updating apt cache"
	sudo apt update || AptError "'apt update' failed!"
#else
#	echo >&2 "apt cache less than an hour old"
fi

echo >&2 "Generating app list. Stand by."

#-----------------------------------------------------------------------------------------
# Fix bugs!
[[ -f /var/lib/dpkg/info/rmsgw.postrm ]] && sudo sed -i -e "s/^cat </bash -c 'cat </" -e "s/ -$/ -'/" /var/lib/dpkg/info/rmsgw.postrm

#-----------------------------------------------------------------------------------------
# Check to see if libc6 updates are available. If yes, then need to apply
# workaround for conflicting ax25.h file with libax25
LIBC_PKGS=("libc6-dev" "libc-dev-bin" "libc6" "libc6-dbg")
printf '%s\n' "${LIBC_PKGS[@]}" >/tmp/libc_packages
if apt list --upgradable 2>/dev/null | grep -qf /tmp/libc_packages
then
	echo >&2 "Checking for libc6 and libax25 conflicts..."
   if [[ -n $(InstalledPkgVersion libax25) ]]
   then
      echo >&2 "libc6 updates available and libax25 installed. Apply ax25.h workaround."
      for F in ${LIBC_PKGS[@]}
      do
         apt download $F
      done
      DEBs="$(printf "%s_*.deb " "${LIBC_PKGS[@]}")"
      sudo dpkg -i --force-overwrite $DEBs
      echo >&2 "Reinstall libax25..."
		InstallLibax25 || { echo >&2 "===== libax25 reinstall failed. ====="; SafeExit 1; }      
		echo >&2 "Done."
      rm -f $DEBs 
	else
  		echo >&2 "Upgrade ${LIBC_PKGS[@]}"
		sudo apt -y install ${LIBC_PKGS[@]} || { echo >&2 "===== ${LIBC_PKGS[@]} upgrade failed. ====="; SafeExit 1; }		
		echo >&2 "Done."
   fi
fi
if apt list --upgradable 2>/dev/null | grep -q "^libax25"
then
   echo >&2 "Upgrade libax25 using libc6 conflict workaround..."
	InstallLibax25 || { echo >&2 "===== libax25 reinstall failed. ====="; SafeExit 1; }      
	echo "Done."   	
fi
rm -f /tmp/libc_packages

#-----------------------------------------------------------------------------------------

if [[ $GUI == $TRUE ]]
then
	RESULT=2
	# Initially generate app list with pick boxes for installed apps not checked
	GenerateList 0
	PICKBUTTON="Select"
	until [[ $RESULT != 2 ]]
	do 
		GenerateTable $PICKBUTTON
		RESULT=$?
		if [[ $RESULT == 2 ]]
		then # User clicked "*Select All Installed" button
			case $PICKBUTTON in
				Select)
					# Generate new list with pick box checked for each installed app
					GenerateList 1
					# Change button so user can de-select pick box for all installed apps
					PICKBUTTON="Unselect"
					;;
				Unselect)
					# Generate new list with pick box unchecked for each installed app
					GenerateList 0
					# Change button so user can check all installed apps.
					PICKBUTTON="Select"
					;;
			esac
		fi	
	done
	rm -f "$TFILE"
	if [[ $RESULT == 1 ]] || [[ $ANS == "" ]]
	then 
   	echo "Update Cancelled"
   	SafeExit 0
	else
		#APP_LIST="$(echo "$ANS" | grep "^TRUE" | cut -d'|' -f2 | tr '\n' ',' | sed 's/,$//')"
		APP_LIST="$(echo "$ANS" | grep "^TRUE" | cut -d'|' -f2 | grep '^[[:alnum:]]' | grep -v -e '^$' )"
		if [[ ! -z "$APP_LIST" ]]
		then
			APP_STRING="$(echo "$APP_LIST" | tr '\n' ',' | sed 's/,$//')"
      	echo "Update/install list: ${APP_STRING}..."    	
      	[[ -z $APP_STRING ]] && { echo "Update Cancelled"; SafeExit 0; }
      	if $0 $APP_STRING
      	then
      		yad --center --title="$TITLE" --info --borders=30 \
    				--no-wrap --text-align=center --text="<b>Finished.</b>\n\n" \
    				--buttons-layout=center --button=Close:0
    			SafeExit 0
    		else  # Errors
      		yad --center --title="$TITLE" --info --borders=30 \
    				--no-wrap --text-align=center \
    				--text="<b>FAILED.  Details in console.</b>\n\n" \
    				--buttons-layout=center --button=Close:0
		     	SafeExit 1
    		fi
      fi
	fi
fi
# If we get here, script was called with apps to install/update, so no GUI



CheckDepInstalled "extra-xdg-menus bc dnsutils libgtk-3-bin jq xdotool moreutils exfatprogs build-essential autoconf automake libtool checkinstall git aptitude python3-tabulate python3-pip dos2unix firefox-esr wmctrl"

DEFAULT_BROWSER="$(xdg-settings get default-web-browser)"
[[ $DEFAULT_BROWSER =~ firefox ]] || xdg-settings set default-web-browser firefox-esr.desktop

APPS="$(echo "${1,,}" | tr ',' '\n' | sort -u)"
for SUSPENDED_APP in $SUSPENDED_APPS
do
    APPS=${APPS/$SUSPENDED_APP/}
done
APPS="$(echo -e $APPS | xargs)"

for APP in $APPS
do
	#APP="$(sed -e "s/$WARN_OPEN//" -e "s/$WARN_CLOSE//" "$APP")"
	#echo "$SUSPENDED_APPS" |  grep -q "$APP" && continue
	cd $SRC_DIR
   case $APP in
   	raspbian)
			echo -e "\n===== Raspbian OS Update Requested ====="
			sudo apt -m -y upgrade && echo -e "===== Raspbian OS Update Finished ====="
			;;
      710)
      	NexusLocalRepoUpdate "710 scripts" $KENWOOD_GIT_URL
      	;;

      nexus-utils)
      	CheckDepInstalled "imagemagick socat wmctrl"
      	NexusLocalRepoUpdate nexus-utils $NEXUS_UTILS_GIT_URL
      	;;

		direwolf-utils)
			CheckDepInstalled "socat"
			NexusLocalRepoUpdate direwolf-utils $DIREWOLF_UTILS_GIT_URL
			;;
		
		rigctl-utils)
			NexusLocalRepoUpdate rigctl-utils $RIGCTL_UTILS_GIT_URL		
			;;
      
		smart-heard)
			NexusLocalRepoUpdate smart-heard $SMARTHEARD_GIT_URL		
			;;
      
      nexus-audio)
			if (NexusLocalRepoUpdate nexus-audio $NEXUS_AUDIO_GIT_URL)
			then
				(pgrep -x fldigi &>/dev/null) && pkill -SIGTERM -x fldigi
				echo >&2 "Restarting pulseaudio..."
				systemctl --user restart pulseaudio 
				echo >&2 "Done."
			fi
      	;;

      nexus-backup-restore)
      	sudo pip3 install mgzip
      	NexusLocalRepoUpdate nexus-backup-restore $NEXUS_BU_RS_GIT_URL
      	;;

      libax25)
      	echo "===== $APP install/update requested ====="
      	if [[ -z $(InstalledPkgVersion libax25) ]] || \
      		[[ $FORCE == $TRUE ]] || \
      		(apt list --upgradable 2>/dev/null | grep -q "^libax25")
			then
				InstallLibax25 || { echo >&2 "===== $APP install/update failed. ====="; SafeExit 1; }
        		echo "===== $APP installed/updated ====="
        	else
				echo "===== $APP already installed and up-to-date  ====="
        	fi
        	sudo apt -y install ax25-apps ax25-tools || { echo >&2 "===== ax25-apps or ax25-tools install/update failed. ====="; SafeExit 1; }
      	;;

		hamlib)
			sudo apt -y install libhamlib4 libhamlib-utils libhamlib-dev || { echo >&2 "===== $APP install/update failed. ====="; SafeExit 1; }
			;;

		arim|garim|ax25mail-utils|direwolf|fldigi|flcluster|flamp|fllog|\
flmsg|flrig|flwrap|gpredict|linpac|ax25-apps|ax25-tools|\
pat|qsstv|rmsgw|uronode|wfview|xastir|wsjtx|js8call)
			sudo apt -y install $APP || { echo >&2 "===== $APP install/update failed. ====="; SafeExit 1; }
        	echo "===== $APP installed/updated ====="
      	;;
      	
   	nexus-update)
   		NexusLocalRepoUpdate nexus-update $NEXUS_UPDATE_GIT_URL
   		;;

      autohotspot)
      	NexusLocalRepoUpdate autohotspot $AUTOHOTSPOT_GIT_URL
      	;;

      chirp)
      	# Remove old local git repo
      	#[[ -d $SRC_DIR/chirp/.git ]] && rm -rf $SRC_DIR/chirp
      	rm -rf $SRC_DIR/chirp
      	mkdir -p $SRC_DIR/chirp
      	_URL="$CHIRPNEXT_URL"
			MAXTRIES=3
			COUNTER=0
			while [ $COUNTER -lt $MAXTRIES ]
			do
				echo >&2 "===== $APP install/upgrade was requested from $_URL ====="
		   	wget -q -O $TMPDIR/chirp.html "$_URL" && break
		  		sleep 5
		  		let COUNTER=COUNTER+1
			done
			if [ $COUNTER -ge $MAXTRIES ]
			then
				echo >&2 "======= $_URL download failed with $? ========"
				SafeExit 1
			fi

			# Obtain the filename of the latest available version and assign it to $href
			eval $(egrep -o 'href="chirp-[[:digit:]]{8}-py3-none-any.whl"' $TMPDIR/chirp.html) || { echo >&2 "======= Failed to find $APP file at $_URL ========"; SafeExit 1; }
			[[ -z $href ]] && { echo >&2 "======= Failed to find $APP file at $_URL ========"; SafeExit 1; }
			
			# Obtain filename of currently installed version
			INSTALLED_VERSION="$($(command -v chirp) --version 2>/dev/null | egrep -o "[[:digit:]]{8}")"
			echo >&2 "Latest version: $(egrep -o '[[:digit:]]{8}' <<<$href)   Installed version: $INSTALLED_VERSION"
			if [[ -n $INSTALLED_VERSION ]]
			then
			   if [[ $href =~ $INSTALLED_VERSION ]]
			   then
			   	if [[ $FORCE == $TRUE ]]
			   	then
			   		#INSTALL_TYPE="reinstall chirp"
			   		INSTALL_TYPE="install --force --pip-args='--force-reinstall' --system-site-packages $SRC_DIR/chirp/$href"
			      else
			      	echo "===== $APP is installed and up to date ====="
			      	continue
			      fi
			   else
					INSTALL_TYPE="upgrade chirp"			   	
			   fi
			else
				INSTALL_TYPE="install --system-site-packages $SRC_DIR/chirp/$href"
			fi
      	#CheckDepInstalled "libfuse2"
      	CheckDepInstalled "git python3-wxgtk4.0 python3-serial python3-six python3-future python3-requests python3-pip"
      	pip3 show pipx &>/dev/null || sudo pip3 install pipx
      	_URL2="$(egrep -o 'Index of /chirp.*[[:digit:]]{8}' $TMPDIR/chirp.html | cut -d' ' -f3)"
			CHIRPFILE_URL="${_URL%/*}${_URL2}/${href}"
			wget -q -O $SRC_DIR/chirp/$href "$CHIRPFILE_URL" || { echo >&2 "======= $CHIRPFILE_URL download failed with $? ========"; SafeExit 1; }
      	if pipx $INSTALL_TYPE 
      	then
      		sudo rm -f /usr/local/bin/chirp /usr/local/bin/chirpc
      		sudo ln -s $HOME/.local/bin/chirp /usr/local/bin/chirp 
      		sudo ln -s $HOME/.local/bin/chirpc /usr/local/bin/chirpc 
      		sudo rm -f /usr/share/applications/chirp.desktop
      		sudo rm -f /usr/bin/chirpw
      		sudo rm -f /usr/local/src/nexus/chirp/Chirp-daily-*.AppImage
      		cat > $HOME/.local/share/applications/chirp.desktop << EOF
[Desktop Entry]
Name=CHIRP
GenericName=Radio Programming Tool
Comment=Program amateur radios
Icon=chirp
Exec=chirp %F
Terminal=false
Categories=HamRadio;
Type=Application
EOF
				wget -q -O $SRC_DIR/chirp/chirp.png "https://github.com/kk7ds/chirp/raw/master/chirp/share/chirp.ico" 2>/dev/null
				[[ -s $SRC_DIR/chirp/chirp.png ]] && sudo cp -f $SRC_DIR/chirp/chirp.png /usr/share/pixmaps/
				echo >&2 "============= $APP installed/updated ================="
      	else
      		echo >&2 "======= 'pipx $INSTALL_TYPE' FAILED!  ========"
      		continue
      	fi
			;;
			
     	linbpq)
     		INSTALL_PMON=$FALSE
     	   mkdir -p linbpq
     		cd linbpq
         echo >&2 "===== LinBPQ install/update requested ====="
         wget -q -O pilinbpq $LINBPQ_URL || { echo >&2 "===== $LINBPQ_URL download failed with $? ====="; SafeExit 1; }
			chmod +x pilinbpq
			# LinBPQ documentation recommends installing app and config in $HOME
     	   if [[ -x $HOME/linbpq/linbpq ]]
     	   then # a version of linbpq is already installed
     	   	INSTALLED_VERSION="$($HOME/linbpq/linbpq -v | grep -i version)"
     	   	LATEST_VERSION="$(./pilinbpq -v | grep -i version)"
        		echo >&2 "Latest version: $LATEST_VERSION   Installed version: $INSTALLED_VERSION"
				if [[ $INSTALLED_VERSION == $LATEST_VERSION && $FORCE == $FALSE ]]
				then # No need to update.  No further action needed for $APP
					echo "===== $APP is installed and up to date ====="
					rm -f pilinbpq
					continue
				else # New version
					echo "===== Installing newer version of $APP ====="
					INSTALL_PMON=$TRUE
				fi
			else # No linbpq installed
				echo "===== Installing LinBPQ ====="
				INSTALL_PMON=$TRUE
			fi
			if [[ $INSTALL_PMON == $TRUE ]]
			then	
				mkdir -p $HOME/linbpq/HTML
				mv -f pilinbpq $HOME/linbpq/linbpq
				DOC="${LINBPQ_DOC##*/}"
				wget -q -O $DOC $LINBPQ_DOC || { echo >&2 "===== $LINBPQ_DOC download failed with $? ====="; SafeExit 1; }
				unzip -o -d $HOME/linbpq/HTML $DOC || { echo >&2 "===== Failed to unzip $DOC ====="; SafeExit 1; }
				rm -f $DOC
				sudo setcap "CAP_NET_ADMIN=ep CAP_NET_RAW=ep CAP_NET_BIND_SERVICE=ep" $HOME/linbpq/linbpq
			fi
     		echo >&2 "===== LinBPQ installed/updated ====="
			;;

      yaac)
         echo >&2 "======== $APP install/upgrade was requested ========="
         echo >&2 "=========== Retrieving $APP from $YAAC_URL ==========="
         mkdir -p YAAC
         cd YAAC
			wget -q $YAAC_URL || { echo >&2 "======= $URL download failed with $? ========"; SafeExit 1; }
         CheckDepInstalled "default-jre libjssc-java"  
         mkdir -p $HOME/YAAC
         unzip -o ${YAAC_URL##*/} -d $HOME/YAAC
         echo >&2 "=========== Installing $APP ==========="
         if [[ ! -s /usr/local/share/applications/YAAC.desktop ]]
         then
        		cat > $HOME/.local/share/applications/YAAC.desktop << EOF
[Desktop Entry]
Name=YAAC
Encoding=UTF-8
GenericName=YAAC
Comment=Yet Another APRS Client
Exec=java -jar $HOME/YAAC/YAAC.jar
Icon=$HOME/YAAC/images/yaaclogo64.ico
Terminal=false
Type=Application
Categories=HamRadio;
EOF
				sudo mv -f $HOME/.local/share/applications/YAAC.desktop /usr/local/share/applications/
			fi
			echo >&2 "============= $APP installed/updated ================="
			;;

      cqrlog)
	      echo "======== $APP install/upgrade was requested ========="
			if (LocalRepoUpdate cqrlog "$CQRLOG_GIT_URL") || [[ $FORCE == $TRUE ]]
			then
				CheckDepInstalled "lazarus lcl fp-utils fp-units-misc fp-units-gfx fp-units-gtk2 fp-units-db fp-units-math fp-units-net libssl-dev mariadb-server mariadb-client libmariadb-dev-compat"
				cd cqrlog
				if make -j4
				then 
					make DESTDIR=$HOME/cqrlog install
        			cat > $HOME/.local/share/applications/cqrlog.desktop << EOF
[Desktop Entry]
Name=CQRLOG
Encoding=UTF-8
GenericName=CQRLOG
Comment=Ham Radio Logger
Exec=$HOME/cqrlog/usr/bin/cqrlog >/dev/null 2>&1
Icon=/usr/share/pixmaps/CQ.png
Terminal=false
Type=Application
Categories=HamRadio;
EOF
           		sudo mv -f $HOME/.local/share/applications/cqrlog.desktop /usr/local/share/applications/
	  				echo >&2 "============= $APP installed/updated ================="
				else
   				echo >&2 "============= $APP install failed ================="	
   				cd $SRC_DIR
   				sudo rm -rf cqrlog
   				SafeExit 1
				fi
			fi
			;;
			
		piardop)
			echo "=========== Installing piardop ==========="
			echo "=========== Downloading $PIARDOP_URL ==========="
			wget -q -O $TMPDIR/piardopc "$PIARDOP_URL" || { echo >&2 "======= ${ARDOP[$V]} download failed with $? ========"; SafeExit 1; }
			chmod +x $TMPDIR/piardopc
			LATEST_VERSION="$($TMPDIR/piardopc -h | grep -i '^ARDOPC Version' | tr -d '\r' | cut -d' ' -f3)"
			INSTALLED_VERSION="$(piardopc -h | grep -i "^ARDOPC Version" | tr -d '\r' | cut -d' ' -f3)"
			[[ -z $LATEST_VERSION ]] && { echo >&2 "======= Unable to determine latest version of piardopc ========"; SafeExit 1; }
			echo "LATEST Version: $LATEST_VERSION    INSTALLED Version: $INSTALLED_VERSION"
			if [[ $INSTALLED_VERSION != $LATEST_VERSION ]]
			then
				sudo mv -f $TMPDIR/piardopc /usr/local/bin/
				echo "=========== piardop version $LATEST_VERSION installed  ==========="
			else
				rm -f $TMPDIR/piardopc
				echo "=========== piardop already at latest version  ==========="
			fi
			;;

      *)
         echo "Skipping unknown app \"$APP\"."
         ;;
   esac
done
SafeExit 0
