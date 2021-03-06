#!/bin/bash
#
#  Remot3 it Control Script manages weaved devices on a platform
#
#  remot3_control <flags> command 
#
#  <optional>  -v = verbose -v -v =maximum verbosity
#
#  will store info in WEAVED_DIR
#
#
#  Weaved Inc : www.weaved.com
#
#

# include shell script lib, must be in path or specify path here
source /usr/bin/remot3_wlib.sh

#set -x

#### Settings #####
VERSION=0.0.4
MODIFIED="June 2, 2016"
#
# Config Dir
#
WEAVED_DIR="/etc/weaved"
#Installed Provisioing files go here (unprovisioned only)
PROVISION_DEFAULT="$WEAVED_DIR/pfiles"
#created devices are in availabe
DEVICES_AVAILABLE="$WEAVED_DIR/available"
#active devices are sym linked in active
DEVICES_ACTIVE="$WEAVED_DIR/active"
#running devices have pidfiles of the same name in running
PID_DIR=/var/run
DEVICES_RUNNING="$PID_DIR/weaved"
#
WEAVED_VERSION="$WEAVED_DIR/weaved_version.txt"
#LOG_DIR="/tmp/"
#LOG_FILE="$LOG_DIR/weaved_log.$$.txt"
LOG_FILE=/dev/null
LOG_DIR=/var/log
#
#
#
BIN_DIR=/usr/bin
DAEMON=weavedconnectd.i686
#
# Save Auth in homedir
#
#SAVE_AUTH=1
#
# use/store authhash instead of password (recommended)
#
USE_AUTHHASH=1
authtype=0 
#
# set reg debug = 1 for debug registration
#
REG_DEBUG=0
REG_ID_ADAPTER="wlan0"
REG_KEY_ADAPTER="eth0"

BULK_REG_DEVICE_FILE="$DEVICES_ACTIVE/rmt3.i686"
#
# Other Globals
#
DEVICE_ADDRESS=""
DEVICE_STATE=""
LIST_ONLY=0
VERBOSE=0
DEBUG=0
PID=0;
TIMEIT=0
FAILTIME=10
#
# API's
#
apiMethod="https://"
apiVersion="/v26/api"
apiServer="api.weaved.com"
#
# API URL's
#
BulkRegisterURL="${apiMethod}${apiServer}${apiVersion}/bulk/registration/register"
ComponentVersionURL="${apiMethod}${apiServer}${apiVersion}/device/component/version"
##### End Settings #####

#
# Built in manpage
#
manpage()
{
#
# Put manpage text here
#
read -d '' man_text << EOF

MANPAGE

EOF
#
printf "\n%s\n\n\n" "$man_text"
}



#
# Print Usage
#
usage()
{
    echo "Usage: $0 command " >&2
    echo "  commands : types typesl status enable disable start stop restart bprovision update updatedeb reset" >&2
    echo "Version $VERSION Build $MODIFIED" >&2
    exit 1 
}

#
# isDirEmpty dir
# returns 1 for empty
#
isDirEmpty()
{
    ret=0
    err="$(ls -A $1 2>&1)"
    if [ "$?" -ne 0 ]; then
        ret=1
    fi
    return $ret
}


#
# factory reset
#
reset()
{
    # delete files
    null=$(rm -f $WEAVED_DIR/*.ver 2>&1)
    null=$(rm -f $DEVICES_AVAILABLE/* 2>&1)
    null=$(rm -f $DEVICES_ACTIVE/* 2>&1)

    # check for success
    isDirEmpty "$WEAVED_DIR/*ver"
    if [ "$?" -eq 1 ]; then
        isDirEmpty "$DEVICES_AVAILABLE/*"
        if [ "$?" -eq 1 ]; then
            isDirEmpty "$DEVICES_ACTIVE/*"
            if [ "$?" -eq 1 ]; then
                echo "OK: factory reset"
                return 0
            fi
        fi
    fi
    echo "FAIL: failed to reset files"
    return 1
}

#
# Customize this for your product
#
get_registration_data()
{
    if [ $REG_DEBUG -gt 0 ]; then
        hardware_id="00:ab:cd:ef:00:FF"
        registration_key="MYSECRET"
    else
        hardware_id=$(cat /sys/class/net/$REG_ID_ADAPTER/address | sed s/://g)
        registration_key=$(cat /sys/class/net/$REG_KEY_ADAPTER/address | sed s/://g) 
    fi
    if [ $VERBOSE -gt 0 ]; then
        printf "Hardware ID is %s registration key is %s\n" $hardware_id $registration_key
    fi
}

#
# update package vesrion to service, this is based on dpkg, may not work for everything
#
# update $name $version
#
update_version()
{
    if [ -n "$2" ]; then
        version="$2"
        # Check against Saved Version
        if [ -f "$WEAVED_DIR/$1.ver" ]; then
            #get saved version
            sversion=$(cat "$WEAVED_DIR/$1.ver")
        fi
        # Check if versions are the same
        if [ "$version" == "$sversion" ]; then
            echo "OK: package $1 version has not changed ($version)"
            return 0
        fi
        #versions are different, try to update 
        # must have rmt as active
        if [ -f "$BULK_REG_DEVICE_FILE" ]; then
            # we have bulk file, lets extract the UID and secret
            uid="$(grep '^UID' "$BULK_REG_DEVICE_FILE" | awk '{print $2}')"
            secret="$(grep 'password' "$BULK_REG_DEVICE_FILE" | awk '{print $2}')"
            #
            # get hardware ID
            get_registration_data
            #push to service
            post='{"hardware_id":"'$hardware_id'","device_address":"'$uid'","device_secret":"'$secret'","component":"'$1'","version":"'$version'"}'
            # make curl call
            resp=$(curl -s -S -X POST -H "content-type:application/json" --data "$post" $ComponentVersionURL )
       
            echo "curl ret $?"

            status=$(jsonval "$(echo -n "$resp")" "status")
            #
            # check return code, if OK cache this new version
            if [ "$status" == "true" ]; then
                echo "$version" > "$WEAVED_DIR/$1.ver" 
                echo "OK: new version $version updated to service for package $1"
            else
                reason=$(jsonval "$(echo -n "$resp")" "reason")
                echo "FAIL: Update $version to service for package $1 failed ($reason)"
                return 1
            fi
        else
            echo "FAIL: Bulk service not enabled, no update to service possible"
            return 2
        fi
    else
        if [ -n "$1" ]; then
            echo "FAIL: no version number specified for $1"
        else
            echo "FAIL: no name or version number specified"
        fi
        return 1
    fi
}

updatedeb()
{
    # package must exist
    # get version from package $1
    version=$(dpkg-query --showformat='${Version}' --show $1)
    if [ "$?" != "0" ]; then
        # no package
        echo "FAIL: no package $1 found "
        return 2
    else
        # update version takes 2 strings
        update_version "$1" "$version"
        return "$?"
    fi
}

update()
{
    # make sure we have 2 strings
    if [ -n "$2" ]; then
        # update version takes 2 strings
        update_version "$1" "$2"
        return "$?"
    else
        if [ -n "$1" ]; then
            echo "FAIL: no version number specified for $1"
        else
            echo "FAIL: no name or version number specified"
        fi
        return 2
    fi
}



#
# killit pid
#
killit()
{
    pid=$1
    ret=1
    kill $pid 
    #wait for pid to die 5 seconds
    count=0                   # Initialise a counter
    while [ $count -lt 5 ]  
    do
	if [ ! -d /proc/$pid ]; then
        #if [ "$pid" != `pidrunning $pid`  ] 
        #then
           ret=0
           break;
        fi
        # not dead yet
        count=`expr $count + 1`  # Increment the counter
        if [ $VERBOSE -gt 0 ]; then
            echo "still running"
        fi
        sleep 1
    done
    return $ret    
}
#
# Stopit name
#
stopit()
{
    ret=1
    if [ -e "$DEVICES_AVAILABLE/$1" ]; then
        if [ -e "$DEVICES_ACTIVE/$1" ]; then
           if [ -e "$DEVICES_RUNNING/$1.pid" ]; then 
                # grab pid
                pid=`cat $DEVICES_RUNNING/$1.pid`;
                # assumes /proc/$pid, if not use pidrunning
                if [ -d /proc/$pid ]; then
                    # shutdown
                    killit $pid
                    retval=$?
                    if [ $retval -ne 0 ]; then
                        echo "FAIL: Could not kill $1 on pid $pid"
                    else
                        ret=0
                        echo "OK: $1 is stopped"
                        rm "$DEVICES_RUNNING/$1.pid"
                    fi
                else
                    ret=0
                    echo "OK: $1 is not running, cleaning up pid file"
                    rm "$DEVICES_RUNNING/$1.pid"
                fi
            else
                ret=0
                echo "OK: $1 is not running"
            fi
        else
            echo "FAIL: $1 Not Active"
        fi
    else
        echo "FAIL: $1 does not exist"
    fi
    return $ret
}

#
# startit name
#
startit()
{
    ret=1
    if [ -e "$DEVICES_ACTIVE/$1" ]; then
        if [ -e "$DEVICES_RUNNING/$1.pid" ]; then
            # Check if already running
            pid=`cat $DEVICES_RUNNING/$1.pid`;
            # assumes /proc/$pid, if not use pidrunning
            if [ -d /proc/$pid ]; then
                ret=0
                echo "OK: Device $1 is already started"    
            else
                #cleanup
                rm "$DEVICES_RUNNING/$1.pid"
            fi
        fi    
        if [ ! -e "$DEVICES_RUNNING/$1.pid" ]; then
            # start it up
            $BIN_DIR/$DAEMON -f "$DEVICES_ACTIVE/$1" -d "$DEVICES_RUNNING/$1.pid" > $LOG_DIR/$1.log
            ret=0
            echo "OK: $1 has started"
        fi
    else
        echo "FAIL: $1 does not exist"
    fi
    return $ret
}

#
# cleanup files that could affect normal operation if things went wrong  cleans up auth
#
cleanup_files()
{
    if [ $VERBOSE -gt 0 ]; then
        printf "Cleaning up Weaved runtime files.  Removing auth file and active files.\n"
    fi   
    # reset auth
    rm -f $AUTH
    rm -f $TOKEN
}

#
# Create Directories if they do not exist
#
create_config()
{
    umask 0077
    # create weaved directory
    if [ ! -d "$WEAVED_DIR" ]; then
        mkdir "$WEAVED_DIR" 
    fi
    # create active dir
    if [ ! -d "$DEVICES_ACTIVE" ] ; then
        mkdir "$DEVICES_ACTIVE"
    fi
    # create available dir
    if [ ! -d "$DEVICES_AVAILABLE" ] ; then
        mkdir "$DEVICES_AVAILABLE"
    fi
    # create active dir
    if [ ! -d "$DEVICES_RUNNING" ] ; then
        mkdir "$DEVICES_RUNNING"
    fi
}
#
# Cleanup, this cleans up the files for the connection, and kills the P2P session if necessary
#
cleanup()
{
    echo ""
}

#
# Control C trap
#
ctrap()
{
    if [ $VERBOSE -gt 0 ]; then
        echo "ctrl-c trap"
    fi

    cleanup
    exit 0;
}

#
# check_auth_cache, one line auth file, type is set to 0 for password and 1 for authash
# 
# Returns $username $password $type on success
#
check_auth_cache()
{
    # check for auth file
    if [ -e "$AUTH" ] ; then
        # Auth file exists, lets get it
        read -r line < "$AUTH"
        # Parse
        username=${line%%"|"*}
        password=${line##*"|"}
        t=${line#*"|"}
        authtype=${t%%"|"*}
        if [ $authtype -eq 1 ]; then
            ahash=$password
        fi
        return 1
    fi
    return 0
}


#
# match_device 
#   match the passed device name to the array and return the index if found or 0 if not
#   if found device_state and device_address are set
#
match_device()
{
    # loop through the device array and match the device name
    for i in "${device_array[@]}"
    do
        # do whatever on $i
        #device_name=$(jsonval "$(echo -n "$i")" "devicealias") 
        device_name=$(jsonval "$i" "devicealias") 
   
        if [ "$device_name" = "$1" ]; then
            # Match echo out the UID/address
            #device_address=$(jsonval "$(echo -n "$i")" "deviceaddress")
            DEVICE_ADDRESS=$(jsonval "$i" "deviceaddress")
            DEVICE_STATE=$(jsonval "$i" "devicestate")
            #echo -n "$DEVICE_ADDRESS"
            return 1
        fi
    done

    #fail
    #echo -n "Not found"
    return 0
}

#
# Device List
#
display_devices()
{
    printf "%-25s | %-15s |  %-10s \n" "Device Name" "Device Type" "Device State"
    echo "--------------------------------------------------------------"
    # loop through the device array and match the device name
    for i in "${device_array[@]}"
    do
        # do whatever on $i
        device_name=$(jsonval "$i" "devicealias")
        device_state=$(jsonval "$i" "devicestate")
        device_service=$(jsonval "$i" "servicetitle")
        printf "%-25s | %-15s |  %-10s \n" $device_name $device_service $device_state
        #echo "$device_name : $device_service : $device_state"
    done
}


#
# Save Auth
#
save_auth()
{
    if [ ! -e "$AUTH" ] ; then
        if [ $VERBOSE -gt 0 ]; then
            echo "Saving Weaved credentials for $username"
        fi
        # Save either pw or hash depending on settings
        if [ $USE_AUTHHASH -eq 1 ]; then
            echo "${username}|1|${ahash}" > $AUTH
        else
            echo "${username}|0|${password}" > $AUTH
        fi
    fi
    # save token
    echo "${token}" > $TOKEN
}


#### Local Data Functions

# itterate through directory
get_provisioning_types()
{

    if [ -v $1 ]; then
        extend=0
    else
        extend=$1
    fi

    for f in $PROVISION_DEFAULT/*
    do
        # list the files
        if [ $extend -eq 1 ]; then
            # get the description for each file
            desc=$(grep desc $f)
            echo "$(basename $f) -${desc#*"desc "}"
        else
            # trim
            echo "$(basename $f) "
        fi
    done    

}

status()
{

if [ -z "${@}" ]; then
    echo "ERROR: status requires one parameter, either specific device or all for all devices"

else

#system status

if [ "$1" == "all" ]; then
    # return the status of all
    # walk through available
    echo "status on all devices"
    tcount=0;
    echo "OK: All "
    for f in $DEVICES_AVAILABLE/*
    do
        if [ "$(basename $f)" != "*" ]; then
            tcount=$((tcount + 1))
            printf "$(basename $f) "
            #
            # Check if enabled
            if [ -e "$DEVICES_ACTIVE/$(basename $f)" ]; then
                printf "enabled "
                #
                # get pid and check for pid
                #
                if [ -e "$DEVICES_RUNNING/$(basename $f).pid" ]; then
                    # get pid and check
                    pid=`cat "$DEVICES_RUNNING/$(basename $f).pid"`;
                    #echo "pid $pid"
                    if [ -d /proc/$pid ]; then 
                        echo "and running"
                    else
                        echo "but not running (cleaning up pid)"
                        rm "$DEVICES_RUNNING/$(basename $f).pid"
                    fi
                else
                    echo "but not running"
                fi

            else
                echo "disabled "
            fi
        fi   
    done
    if [ $tcount -eq 0 ]; then
        echo "no devices found"
    fi
else
    echo "OK: $1"
    # look for a specific device
    if [ -e "$DEVICES_AVAILABLE/$1" ]; then
        printf "$1 "
        # Check if enabled
        if [ -e "$DEVICES_ACTIVE/$1" ]; then
            printf "enabled "
            if [ -e "$DEVICES_RUNNING/$1.pid" ]; then
                pid=`cat "$DEVICES_RUNNING/$1.pid"`;    
                #echo "pid $pid"
                if [ -d /proc/$pid ]; then
                    echo "and running" 
                else
                    echo "but not running (cleaning up pid)"
                    rm "$DEVICES_RUNNING/$1.pid"
                fi
            else
                echo "but not running"
            fi
        else
            echo "not running"
        fi
    else
        echo "no device named $1 found" 
    fi
fi

fi

}

#list all avaailable
list()
{
    status all
}


#bulk provision a specific pfile do not call directly call bprovsion()
bprovisionit()
{
    if [ $VERBOSE -gt 0 ]; then
        printf "Try to bulk provision %s\n" $1
    fi
    #extract the project ID 
    project_id=$(grep -A1 \#begin "$PROVISION_DEFAULT/$1" | grep -v \#begin)
    #idlen=expr length "$project_id"
    idlen=${#project_id} 
    if [ $idlen -eq 36 ]; then
        # we have provsioning file lets make call
        get_registration_data
        if [ $VERBOSE -gt 0 ]; then
            printf "Call API with project_id %s with hwid and reg key.\n" $project_id
        fi

        # make curl call
        data='{"project_id":"'$project_id'","hardware_id" : "'$hardware_id'", "registration_key" : "'$registration_key'"}'
        resp=$(curl -s -S -X POST -H "content-type:application/json" --data "$data" $BulkRegisterURL )
        
        status=$(jsonval "$(echo -n "$resp")" "status")
      
        case "$status" in
        "true")
            # got a 200 lets do it
            uid=$(jsonval "$resp" "uid")
            secret=$(jsonval "$resp" "secret")
            # we have reg stuff lets create it
            cp "$PROVISION_DEFAULT/$1" "$DEVICES_AVAILABLE/$1"
            echo "UID $uid" >> "$DEVICES_AVAILABLE/$1"
            echo "password $secret" >> "$DEVICES_AVAILABLE/$1"
            #
            echo "OK: $1 is provisioned"
            #
            # Activate it
            enable $1
            # start it
            start $1
        ;;
        "false")
            reason=$(jsonval "$(echo -n "$resp")" "reason")
            if [ $VERBOSE -gt 0 ]; then
                printf "Server Said = %s\n" "$reason"
            fi
            printf "FAIL: %s: %s\n" "$1" "$reason"
            return 1
        ;;
        *)
            if [ $VERBOSE -gt 0 ]; then
                printf "Curl Call failed with error. output= %s\n" $status
            fi
            echo "FAIL: error talking to server"
            return 1
        ;;
        esac 


    else
        if [ $VERBOSE -gt 0 ]; then
            printf "Provisioning file corrupt for %s\n" $1
        fi
        return 2
    fi
    return 0
}

# bulk provision
bprovision()
{
    ret=1
    rc=1
    if [ -z "${@}" ]; then
        ret=3
        echo "ERROR: enable requires one parameter, either specific device name or all for all devices"
    else
        if [ "$1" == "all" ] || [ -z "${@}" ]; then
            # to bulk provision must be in pfiles but not avaialble
            for f in $PROVISION_DEFAULT/*
            do
                base=$(basename $f)
                if [ "$base" != "*" ]; then
                    #see if this is also in available, if not try to provision
                    if [ ! -f "$DEVICES_AVAILABLE/$base" ]; then
                        ret=0
                        # Try to bulk provision
                        bprovisionit $base
                        if [ "$?" -eq 0 ]; then
                            # set that we have done something
                            rc=0
                        fi
			            sleep 1
                    fi
                fi
            done
            if [ $ret -ne 0 ]; then
                echo "FAIL: nothing to provision"
                ret=1
            fi
        else
            if [ -e "$PROVISION_DEFAULT/$1" ]; then   
                if [ ! -f "$DEVICES_AVAILABLE/$1)" ]; then 
                    # Try to bulk provision
                    bprovisionit $1
                fi
            else
                echo "FAIL: $1 not found"
                ret=1
            fi 
        fi
    fi

    return $rc
}


# symlink the available to enabled
enable()
{
    ret=1
    if [ -z "${@}" ]; then
        echo "ERROR: enable requires one parameter, either specific device name or all for all devices"
    else
        if [ "$1" == "all" ] || [ -z "${@}" ]; then
            echo "OK: enable all"
            #itterate through available files and symlink to active
            for f in $DEVICES_AVAILABLE/*
            do
                base=$(basename $f)
                if [ "$base" != "*" ]; then
		    ret=0
                    # active is a symlink so need to use -e here
                    if [ -e "$DEVICES_ACTIVE/$base" ]; then
                        echo "OK: $(basename $f) already enabled"
                    else
                        ln -s $f "$DEVICES_ACTIVE"
                        echo "OK: $base enabled"
                    fi
                fi
            done 
            if [ $ret -ne 0 ]; then
                echo "FAIL: notihing to enable"
            fi
        else
            if [ -e "$DEVICES_AVAILABLE/$1" ]; then
                if [ -e "$DEVICES_ACTIVE/$1" ]; then
                    echo "OK: $1 already enabled"
                else 
                    echo "OK: $1 enabled"
                    ln -s "$DEVICES_AVAILABLE/$1" "$DEVICES_ACTIVE"
                fi
            else
                echo "ERROR: $1 not found"
            fi

        fi
    fi
    return 0
}

#stop if running remove symlink
disable()
{
    ret=1
    if [ -z "${@}" ]; then
        echo "ERROR: disable requires one parameter, either specific device name or all for all devices"
    else
        if [ "$1" == "all" ]; then
            echo "OK: disable all"
            for f in $DEVICES_AVAILABLE/*
            do
                base=$(basename $f)
                if [ "$base" != "*" ]; then
                    if [ -e "$DEVICES_ACTIVE/$base" ]; then
                        ret=0
                        stopit $base
                        echo "OK: $base disabled"
                        rm "$DEVICES_ACTIVE/$base"
                    fi 
               fi
            done
            if [ $ret -ne 0 ]; then
                echo "FAIL: noting to disable"
            fi
        else
            if [ -e "$DEVICES_ACTIVE/$1" ]; then
                stopit $1
                echo "OK: disable $1"
                rm "$DEVICES_ACTIVE/$1"
            else
                echo "FAIL: $1 not active"
            fi
            return 1
        fi
    fi        
    return 0
}

#startup the device
start()
{
    ret=1
    if [ -z "${@}" ]; then
        echo "ERROR: start requires one parameter, either specific device name or all for all devices"
    else
        if [ "$1" == "all" ]; then
            #loop through all enabled but not active devices and start them
            for f in $DEVICES_ACTIVE/*
            do
                base=$(basename $f)
                if [ "$base" != "*" ]; then
		    ret=0
                    startit $base
                fi
            done
            if [ $ret -ne 0 ]; then
                echo "FAIL: No active devices to start"
            fi
        else
            #start the device if not running and is available
            if [ -e "$DEVICES_AVAILABLE/$1" ]; then
                if [ -e "$DEVICES_ACTIVE/$1" ]; then
                    # see if really running
                    startit $1
                    ret=$?
                else 
                    echo "FAIL: $1 is not active"
                    ret=1
                fi
            else
                echo "FAIL: $1 does not exist"
                ret=1
            fi
        fi
    fi
    return $ret
}

#shutdown the device
stop()
{
    ret=1
    if [ -z "${@}" ]; then
        echo "ERROR: stop requires one parameter, either specific device name or all for all devices"
    else
        if [ "$1" == "all" ]; then          
            #loop through all running devices and stop them
            for f in $DEVICES_ACTIVE/*
            do
		base=$(basename $f)
                if [ "$base" != "*" ]; then
                   ret=0
                   stopit $base
		fi
            done
            if [ $ret -ne 0 ]; then
                echo "FAIL: No active devices to stop"
            fi
        else
            #stop one device
            stopit $1
            ret=$?
        fi
    fi
    return $ret
}

#restart the device
restart()
{
    stop $@
    ret=$?
    sleep 1
    start $@
    ret=$?
    return $ret
}

#create a device
create()
{
    type=$1
    name=$2
    ip=$3
    port=$4

    if [ -z "${type}" ] || [ -z "${name}" ] || [ -z "${ip}" ] || [ -z "${port}" ]; then
        echo "ERROR: create requires 4 parameters, [type] [name] [ip] [port].  Assumes authentication is good"
        echo "type is an avalable provisioning type, name is what you want to call the device, IP is the target IP, port is th target port."
    else
        # check that type exists
        type=$1
        if [ -e "$PROVISION_DEFAULT/$1" ]; then
            #found get rest of values
            echo "create $type - $name - $ip - $port"
            return 0
        else
            echo "ERROR: no provisioning type $type found"
        fi
    fi
    return 1
}

#delete a device, should preserve UID if deleted
delete()
{
    if [ -z "${@}" ]; then
        echo "ERROR: delete requires one parameter, either specific device name or all for all devices"
    else
        if [ "$1" == "all" ]; then
            #loop through all running devices and delete them
            echo "all"
        else
            #stop one device
            if [ -e "$DEVICES_AVAILABLE/$1" ]; then
                if [ -e "$DEVICES_ACTIVE/$1" ]; then
                    # shutdown device before delete, let hide output
                    tmp=$(stop $1)
                fi
                # now lets delete device from service
                
                # now delete provisioning file (we should save UID)
                return 0
            else
                echo "ERROR: $1 does not exist"
            fi    
        fi
    fi
    return 1
}

login()
{
    username=$1
    password=$2

    if [ -z "${username}" ] || [ -z "${password}" ]; then
        echo "ERROR: login requires 2 parameters, [username] [password]."
    else
        # reset current auth
        cleanup_files    
        # try to login 
        userLogin
        
        # check return value and exit if error
        retval=$?
        if [ "$retval" == 0 ]; then
            echo "ERROR: $loginerror"
            return 1 
        fi
        echo "OK: logged in"     
        return 0
    fi
    return 1
}

logout()
{
    #reset current auth
    cleanup_files
    echo "OK: logged out"
    return 0
}

###############################
# Main program starts here    #
###############################
#
# Create the config directory if not there
#
#echo "Weave Control Version $VERSION $MODIFIED"
create_config

################################################
# parse the flag options (and their arguments) #
################################################
while getopts lvhmcr OPT; do
    case "$OPT" in
      p)
        echo "Installed Provisioning Types"
        get_provisioning_types 1
        exit 0
        ;;
      m)
        manpage
        exit 0
        ;;
      v)
        VERBOSE=$((VERBOSE+1)) ;;
      h | [?])
        # got invalid option
        usage
        ;;
    esac
done

# get rid of the just-finished flag arguments
shift $(($OPTIND-1))

#now lets get command

command=$1

case "$command" in
    "types")
        get_provisioning_types 0 
        ;;
    "typesl")
        get_provisioning_types 1
        ;;
    "status")
        shift
        status $@
        ;;
    "list")
        shift
        list $@
        ;;
    "bprovision")
        shift
        bprovision $@
        ;;
    "enable")
        shift
        enable $@
        ;;
    "disable")
        shift
        disable $@
        ;;
    "start")
        shift
        start $@
        ;;
    "stop")
        shift
        stop $@
        ;;
    "restart")
        shift
        restart $@
        ;;
    "update")
        shift
        update $@
        ;;
    "updatedeb")
        shift
        updatedeb $@
        ;;
    "reset")
        shift
        reset $@
        ;;
    *)
        usage
        exit 1
        ;;
esac

exit $?






