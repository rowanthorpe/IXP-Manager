#!/bin/sh

# ixpm-bird-configure.sh
# Copyright (C) 2014 GRNET S.A.
# By Rowan Thorpe, based largely on an example script by
# Barry O'Donovan <barry@opensolutions.ie>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

## settings

CONFNAME="`hostname --fqdn | cut -d. -f1`"
KEY="......"
URL="https://example.com/apiv1/router/server-conf/key/${KEY}"
VLANS='1 2' # list of vlanids (DB table IDs) for running in "all" mode

PROTOCOLS='4 6'
ETCPATH="/etc/bird"
RUNPATH="/var/run/bird"
BIN="/usr/sbin/bird"
ADD_TO_PATH='/usr/local/bin'
BGP_GREP_STRING='protocol bgp b_' # this is a grep-arg, escape where needed
DEBUG=0
QUIET=0

vlanid=''
proto=''
scriptname="`printf '%s' "$0" | sed -n -e '$! b; s:^.*/\([^/]\+\)$:\1:; p'`"

## get consistency between shells

# TODO: adding $KSH_VERSION to this test works for pdksh but kills ksh
# (how to distinguish between those two shells?)
test -z "$BASH_VERSION" || set -o posix
if test -n "$ZSH_VERSION"; then
    setopt shwordsplit
    NULLCMD=':'
    export NULLCMD
fi

## functions

show_help() { printf '%s [-d] [-v <vlan-db-id> -p <protocol(4/6)>] | [-h|-?]\n' "$scriptname"; }

debug_print() { test 1 -ne $DEBUG || printf "$@"; }

noquiet_print() { test 1 -eq $QUIET || printf "$@"; }

generate_conf() {
    # "mkdir -p" may still error if a *non-directory* already exists with that name
    cmd="mkdir -p \"$RUNPATH\""
    debug_print '%s\n' "$cmd"
    eval "$cmd" >/dev/null 2>&1
    test $? -eq 0 || { printf 'ERROR: non-zero return from "mkdir -p %s"\n' "$RUNPATH"; return 7; }
    cmd="mkdir -p \"$ETCPATH\""
    debug_print '%s\n' "$cmd"
    eval "$cmd" >/dev/null 2>&1
    test $? -eq 0 || { printf 'ERROR: non-zero return from "mkdir -p %s"\n' "$RUNPATH"; return 7; }
    # to generate the appropriate bird commands:
    if test 6 = "$proto"; then
        PROTOCOL=6
    else
        PROTOCOL=''
    fi
    cmd="mktemp -q \"${ETCPATH}/bird-vlanid${vlanid}-ipv${proto}.conf.XXXXXX\""
    debug_print '%s\n' "$cmd"
    dest="$(eval "$cmd" 2>/dev/null)"
    test $? -eq 0 || { printf 'ERROR: non-zero return from mktemp\n'; return 2; }
    cmd="wget -q -O \"$dest\" \
\"${URL}/target/bird/vlanid/${vlanid}/proto/${proto}/config/${CONFNAME}-vlan${vlanid}-ipv${proto}\""
    debug_print '%s\n' "$cmd"
    eval "$cmd" >/dev/null 2>&1
    # we want to be bullet proof here so we really want to check the generated file to try
    # and ensure it is valid
    test $? -eq 0 || { printf 'ERROR: non-zero return from wget when generating %s\n' "$dest"; return 2; }
    test -s "$dest" || { printf 'ERROR: %s does not exist or is zero size\n' "$dest"; return 3; }
    test $(cat "$dest" | grep "$BGP_GREP_STRING" | wc -l) -ge 2 || \
        { printf 'ERROR: <2 BGP protocol definitions in config file %s - something has gone wrong...\n' "$dest"; return 4; }
    # parse and check the config
    cmd="\"${BIN}${PROTOCOL}\" -p -c \"$dest\""
    debug_print '%s\n' "$cmd"
    eval "$cmd" >/dev/null 2>&1
    test $? -eq 0 || { printf 'ERROR: non-zero return from bird%d when parsing %s\n' "$PROTOCOL" "$dest"; return 7; }
    # back up the current one
    if test -e "${ETCPATH}/bird${PROTOCOL}.conf"; then
        cmd="cp -f \"${ETCPATH}/bird${PROTOCOL}.conf\" \"${ETCPATH}/bird${PROTOCOL}.conf.old\""
        debug_print '%s\n' "$cmd"
        eval "$cmd" >/dev/null 2>&1
        test $? -eq 0 || { printf 'ERROR: non-zero return from copying original config "%s" to "%s"\n' "${ETCPATH}/bird${PROTOCOL}.conf" "${ETCPATH}/bird${PROTOCOL}.conf.old"; return 8; }
    fi
    # mv new one into place
    cmd="mv -f \"$dest\" \"${ETCPATH}/bird${PROTOCOL}.conf\""
    debug_print '%s\n' "$cmd"
    eval "$cmd" >/dev/null 2>&1
    test $? -eq 0 || { printf 'ERROR: non-zero return from moving new config "%s" to "%s"\n' "$dest" "${ETCPATH}/bird${PROTOCOL}.conf"; return 9; }
    # are we running or do we need to be started?
    cmd="\"${BIN}c${PROTOCOL}\" -s \"${RUNPATH}/bird${PROTOCOL}.ctl\" show memory"
    debug_print '%s\n' "$cmd"
    eval "$cmd" >/dev/null 2>&1
    if test $? -ne 0; then
        cmd="\"${BIN}${PROTOCOL}\" -c \"${ETCPATH}/bird${PROTOCOL}.conf\" -s \"${RUNPATH}/bird${PROTOCOL}.ctl\""
        debug_print '%s\n' "$cmd"
        eval "$cmd" >/dev/null 2>&1
        test $? -eq 0 || { printf 'ERROR: bird%d was not running for %s and could not be started\n' "$PROTOCOL" "$dest"; return 5; }
    else
        cmd="\"${BIN}c${PROTOCOL}\" -s \"${RUNPATH}/bird${PROTOCOL}.ctl\" configure"
        debug_print '%s\n' "$cmd"
        eval "$cmd" >/dev/null 2>&1
        if test $? -ne 0; then
            printf 'ERROR: Reconfigure failed for %s\n' "$dest"
            if test -e "${ETCPATH}/bird${PROTOCOL}.conf.old"; then
                printf 'Trying to revert to previous\n'
                cmd="mv -f \"${ETCPATH}/bird${PROTOCOL}.conf\" \"$dest\""
                debug_print '%s\n' "$cmd"
                eval "$cmd" >/dev/null 2>&1
                # ignore failure here (we only care about the original config)
                cmd="mv -f \"${ETCPATH}/bird${PROTOCOL}.conf.old\" \"${ETCPATH}/bird${PROTOCOL}.conf\""
                debug_print '%s\n' "$cmd"
                eval "$cmd" >/dev/null 2>&1
                # ignore failure here (reload already failed, can't hurt to try again...)
                cmd="\"${BIN}c${PROTOCOL}\" -s \"${RUNPATH}/bird${PROTOCOL}.ctl\" configure"
                debug_print '%s\n' "$cmd"
                eval "$cmd" >/dev/null 2>&1
                if test $? -eq 0; then
                    printf 'Successfully reverted\n'
                else
                    printf 'Reversion failed\n'; return 6
                fi
            fi
        fi
    fi
    return 0
}

## main

while getopts "h?qdv:p:" opt; do
    case "$opt" in
        h|\?)
            show_help
            exit 0
            ;;
        d)  DEBUG=1
            ;;
        v)  vlanid=$OPTARG
            ;;
        p)  proto=$OPTARG
            ;;
        q)  QUIET=1
            ;;
    esac
done
shift `expr $OPTIND - 1`

for addtopath in $ADD_TO_PATH; do
    PATH="${PATH}:$addtopath"
done
export PATH

if test -n "${vlanid}${proto}"; then
    if test -z "$vlanid"; then
        printf 'ERROR: VLAN ID parameter -v is required when Protocol parameter -p is present\n'
        exit 1
    elif test -z "$proto"; then
        printf 'ERROR: Protocol parameter -p is required when VLAN ID parameter -v is present\n'
        exit 1
    fi
    if ! test 4 = "$proto" && ! test 6 = "$proto"; then
        printf 'ERROR: Invalid protocol %s specified\n' "$proto"
        exit 1
    fi
    # override the "full" list with single combination from flags
    VLANS="$vlanid"
    PROTOCOLS="$proto"
fi

noquiet_print 'Reconfiguring bird instance(s):\n'
for vlanid in $VLANS; do
    noquiet_print 'VLAN ID %s: ' "$vlanid"
    for proto in $PROTOCOLS; do
        noquiet_print '\tIPv%d: ' "$proto"
        if test 1 -eq $QUIET && test 1 -ne $DEBUG; then
            generate_conf >/dev/null 2>&1
        else
            generate_conf
        fi
        retval=$?
        if test $retval -eq 0; then
            noquiet_print 'OK      '
        else
            noquiet_print 'ERROR %d ' "$retval"
        fi
    done
    noquiet_print '\n'
done
exit $retval
