#!/bin/bash

# This script will grab a `pstack` of an SSSD process every
# ${sleepInt} seconds and store it in the custom directory ${pstackDir}.

# Variables to unset later if script closes:
unset_vars_later=(sleepInt runningProc givenDir parentDir dieThreshold freeSpace pstackDir fileNum currDate procPid runningProc procList pstackSize volumeAvai debugMissing)

# Trap [CTRL + C] and clean up if pressed
trap ctrl_c INT
function ctrl_c() {
	echo -e "\n\n[CTRL + C] pressed. Performing housekeeping and stopping the script.";
	for var in "${unset_vars_later[0]}"; do
		unset "$var"
	done
	if [ -n "$pstackDir" ]; then
		echo -e "\nThe below directory contains the stacks:\n${pstackDir}\n";
	fi
	exit 1
}

# Do not run if not root
if [[ $UID -ne 0 ]];
	then
	echo -e "\nThis script must be run as root.\n";
	exit 1
fi

# Set some vars

# Threshold for safety reasons (1.5G)
dieThreshold=1500000

# File counter
fileNum=0;

# We need gdb
if rpm -q "gdb" &> /dev/null; then
	echo -e "\nVerified $(rpm -q gdb) is installed..\n";
else
	echo -e "\nPackage 'gdb' not found.";
	read -p "Would you like to install it now with 'dnf install gdb -y'? (y/n) " -n 1 -r
	echo;
	if [[ $REPLY =~ ^[Yy]$ ]]; then
		echo -e "\nInstalling gdb..\n";
		if dnf install gdb -y; then
			echo -e "\n'gdb' installed successfully. Continuing..\n";
		else
			echo -e "\nFailed to install 'gdb'. Please investigate and try again.\n";
			for var in "${unset_vars_later[0]}"; do
				unset "$var"
			done
			exit 1
		fi
	else
		echo -e "\nPlease install 'gdb' manually and run this script again.\n";
		for var in "${unset_vars_later[0]}"; do
			unset "$var"
		done
		exit 1
	fi
fi

# Script info:
echo -e "This script will grab pstacks of the chosen SSSD process every few seconds..\n";

# How often are we dumping?
echo "It is suggested to let this script run once every 1/3 of the "timeout" value";
echo -e "which is set in the DOMAIN and SERVICES sections of sssd.conf. Default: 10\n";
echo "How often should we run? (3 to 5 seconds is preferred):";
read -p "> " sleepInt; echo;
while [[ ! "$sleepInt" =~ ^-?[0-9]+$ ]]; do
	echo "That's not a number. Try again.";
	read -p "> " sleepInt; echo;
done

# Which SSSD process are we dumping?
procList=$(systemctl status sssd | sed -n '/\/usr\//{s/.*\/\([^ ]*\).*/\1/p}' | sed '/\.service/d')
echo -e "Currently running SSSD processes:\n";
echo -e "${procList}\n";
echo "Which of the above are we dumping? (Example: sssd_be)";
read -p "> " runningProc; echo;
while ! echo "$procList" | grep -q "^$runningProc$"; do
	echo "${runningProc} is not in the list. Try again.";
	read -p "> " runningProc; echo;
done
procPid="$(pidof ${runningProc})";
echo -e "${runningProc} (${procPid}) chosen..\n";

# We should install debuginfo packages for the chosen process
echo -e "NOTE: You should install any missing debuginfo packages for ${runningProc} before continuing!";
echo -e "Check for missing debuginfo packages by exiting this script and running:\n";
echo -e "sudo gdb -p ${procPid}\n";
read -p "Should we stop so you can check the above? (y/n) " -n 1 -r; echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
	echo -e "\nWe will exit.";
	echo -e "NOTE: The gdb output will look like:";
	echo -e "\nMissing separate debuginfos, use: dnf debuginfo-install \$PACKAGE_LIST\n";
	echo -e "If missing packages are found, run the given dnf command with the full list of packages.";
	echo -e "You may need to run gdb several times to find other missing packages after running dnf.";
	echo -e "\nExiting.";
	for var in "${unset_vars_later[0]}"; do
		unset "$var"
	done
	exit 1
fi

# Where are we dumping to?
echo -e "\nWhere are the stacks going? (Example: /tmp)";
read -p "> " givenDir; echo;
parentDir=$(echo ${givenDir}|sed 's:/*$::');

# Make the dir if it doesn't exist?
if [ -d "$parentDir" ]; then
	echo -e "${parentDir} exists. A stack directory will be created here.\n";
else
	read -p "$parentDir doesn't exist. Create it? (y/n) " -n 1 -r
	echo;
	if [[ $REPLY =~ ^[Yy]$ ]]; then
		echo -e "\nCreating $parentDir"
		mkdir -p "$parentDir"
	else
		echo -e "\nOkay, exiting.";
		for var in "${unset_vars_later[0]}"; do
			unset "$var"
		done
		exit 0
	fi
fi

# Die if there's not enough space (1.5G or less)
freeSpace=$(df ${parentDir}|awk 'NR==2 {print $4}')
if [[ "$freeSpace" -lt "$dieThreshold" ]]; then
	echo -e "\nThere's less than 1.5G of free space on ${parentDir} ..";
	echo -e "Shutting down for safety.\n";
	for var in "${unset_vars_later[0]}"; do
		unset "$var"
	done
	exit 1
fi

# Notify of free space
echo -e "\nNote: ${parentDir} has $(df -Ph ${parentDir}|awk 'NR==2 {print $4}') of free space.";
read -p "Press [ENTER] if this is ok or [CTRL + C] to quit.."; echo;

# Make the dir in ${parentDir} for storage
pstackDir="${parentDir}/${runningProc}_pstacks_$(date +%F_%H:%M)";
mkdir ${pstackDir};
echo -e "Created ${pstackDir} for storage..\n";

# Start looping and generating stacks:
echo -e "Running every ${sleepInt} seconds..\n";
while true; do

	# Die if there's not enough space (1.5G or less)
	freeSpace=$(df ${parentDir}|awk 'NR==2 {print $4}')
	if [[ "$freeSpace" -lt "$dieThreshold" ]]; then
		echo -e "\nThere's less than 1.5G of free space on ${parentDir} ..";
		if [ -n "$pstackDir" ]; then
			echo -e "\nThe below directory contains the stacks:\n${pstackDir}\n";
		fi
		echo -e "Shutting down for safety.\n";
		for var in "${unset_vars_later[0]}"; do
			unset "$var"
		done
		exit 1
	fi

	# Set the PID of the chosen proc
	procPid="$(pidof ${runningProc})";

	# Notify if the proc is dead
	if [[ -z "$procPid" ]]; then
		echo -e "\nOops! ${runningProc} has stopped running. We will wait until it is back up.\n";
		while [ -z "$procPid" ]; do
			sleep 0.5
			procPid="$(pidof ${runningProc})";
		done
	fi

	# Check for any WATCHDOG alerts for SSSD in the last 30 seconds
	if journalctl --since "30 seconds ago" -u sssd | grep -q WATCHDOG; then
		echo -e "A recent SSSD WATCHDOG alert has been detected. This may be a good place to stop [CTRL +C].";
	fi

	# Increment file counter
	let fileNum++;

	# Set a timestamp variable
	currDate=$(date +%F_%H:%M:%S);

	# Dump a stack trace of sssd_be
	pstack ${procPid} > ${pstackDir}/${runningProc}_${procPid}_${currDate}.pstack;

	# Store some space values
	pstackSize=$(du -sh ${pstackDir}/${runningProc}_${procPid}_${currDate}.pstack|awk '{print $1}')
	volumeAvai=$(df -Ph ${parentDir}|awk 'NR==2 {print $4}')

	# Tell what we did
	echo -e "(${fileNum}) ${runningProc}_${procPid}_${currDate}.pstack | Size: ${pstackSize} | Space Available: ${volumeAvai}";

	# Sleep for ${sleepInt} seconds and run again
	sleep ${sleepInt};

	done
}
