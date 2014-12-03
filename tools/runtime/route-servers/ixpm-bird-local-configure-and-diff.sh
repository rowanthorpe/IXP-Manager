#!/bin/sh

# ixpm-bird-local-configure-and-diff.sh
# Copyright (C) 2014 GRNET S.A.
# Written by Rowan Thorpe
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

ROUTE_SERVERS='0 1'
RS_TARGETS='bird'
PEERING_LANS='100'
IP_VERSIONS='4 6'
MAIL_RECIPIENTS="noc@example.com"

APP_PATH="/opt/ixpmanager"
CONF_DIR="/etc/ixpmanager"
IXPM_CONF_FILE='/etc/ixpmanager.conf'
OUTPUT_DIR="/var/lib/ixpmanager/rsconfigs"
ANSI2HTML='/usr/local/bin/ansi2html.sh --bg=dark --palette=xterm'
MAILX='/usr/bin/bsd-mailx' # this must be classic-bsd-mailx compatible
GEN_EMAIL_NICE='10' # how much to "nice" the process for creating html output (empty=don't nice)
BASE64='base64'
#QPRINT='qprint'
HOSTNAME="`hostname --fqdn`"

DEBUG=0
STDOUT=0
UPDATE_DB=1
USE_GIT=1

scriptname="`printf '%s' "$0" | sed -n -e '$! b; s:^.*/\([^/]\+\)$:\1:; p'`"
trap_exit_code=''

## get consistency between shells

# TODO: adding $KSH_VERSION to this test works for pdksh but kills ksh
# (how to distinguish between those two shells?)
test -z "$BASH_VERSION" || set -o posix
if test -n "$ZSH_VERSION"; then
    setopt shwordsplit
    NULLCMD=':'
    export NULLCMD
fi

#TODO: the ansi2html.sh I found which is thorough enough to do it well is hideously inefficient
#      and soaks up CPU for *minutes*. For now I just make it configurably niceable, as we don't
#      need results *that* urgently, but it would be better to find a more efficient converter
#      at some point (even if much simpler)

## functions

bork() {
    errorcode=$1
    shift
    printf 'ERROR: %s: %s. Failed with error code %d.\n' "$scriptname" "$*" "$errorcode" >&2
    exit 1
}

quote_list() {
    for arg do
        printf "%s" "$arg" | sed -e "s/'/'\\\\''/g; s/^/'/; s/\$/', /"
    done | sed -e 's/, $//'
}

## main

test 0 -eq `id -u` || bork $? 'not running as root'
while test 0 -ne $#; do
    case "$1" in
        --help|-h)
            cat <<EOF
Usage: $scriptname [OPTIONS] [--]

DESCRIPTION

 Update IXP-Manager's prefix and ASN tables, and generate route-server configs, with
 git version-tracking and emailing on changes. Useful for running from cron for
 regular updates.

OPTIONS

 --help, -h      : this message
 --debug, -d     : spill info to stdout/stderr
 --stdout, -O    : output configs to stdout and don't generate files
 --no-update, -u : don't do the DB updates first, just generate configs
 --no-git, -g    : don't track changes in git

EOF
            exit 0
            ;;
        --debug|-d)
            DEBUG=1
            shift
            ;;
        --stdout|-O) # generate configs to stdout (AS/prefix-updates still update DB)
            STDOUT=1
            shift
            ;;
        --no-update|-u) # don't update ASes and prefixes, just generate configs
            UPDATE_DB=0
            shift
            ;;
        --no-git|-g)
            USE_GIT=0
            shift
            ;;
        --)
            shift
            break
            ;;
        -*)
            bork 1 "in getopts (option \"$1\")"
            ;;
        *)
            break
            ;;
    esac
done
if test 0 -eq $DEBUG; then
    verb=''
else
    verb="-v"
fi
if test 1 -eq $UPDATE_DB; then
    "${APP_PATH}/bin/ixptool.php" $verb -a 'irrdb-cli.update-prefix-db' || \
        bork $? 'irrdb-cli.update-prefix-db'
    "${APP_PATH}/bin/ixptool.php" $verb -a 'irrdb-cli.update-asn-db' || \
        bork $? 'irrdb-cli.update-prefix-db'
fi
if test 0 -eq $STDOUT; then
    test -d "${OUTPUT_DIR}" || mkdir $verb -p "${OUTPUT_DIR}" || \
        bork $? "creating output dir \"$OUTPUT_DIR\""
fi
ixpm_conf="$(cat "$IXPM_CONF_FILE")"
for field in dbase_type dbase_database dbase_username dbase_password dbase_hostname dbase_portname; do
    eval "${field}"'=`printf "%s" "$ixpm_conf" | sed -n -e "s/^[ \\t]*${field}[ \\t]*=[ \\t]*\\([^ \\t].*\\)\$/\1/; t PRINT; b; : PRINT; s/ \\+\$//; p; q"`'
done
case "$dbase_type" in
    mysql)
        trap_exit_code="$trap_exit_code
"'test -z "$temp_defaults" || rm -f "$temp_defaults" 2>/dev/null'
        trap "$trap_exit_code" EXIT
        temp_defaults="`mktemp`" && chmod go= "$temp_defaults" || \
            bork $? 'creating temp defaults file'
        cat <<EOF >"$temp_defaults" || bork $? 'populating temp defaults file'
[mysql]
user=$dbase_username
password=$dbase_password
database=$dbase_database
`test -z "$dbase_hostname" || printf 'host=%s' "$dbase_hostname"`
`test -z "$dbase_portname" || printf 'port=%s' "$dbase_portname"`
skip-column-names
batch
EOF
        database_cmd="mysql --defaults-file=\"$temp_defaults\" | tr '\\n' ' ' | sed -e 's/\\t/|/g; s/ \$//'"
        ;;
    *)
        bork 1 "$dbase_type database type handling not yet implemented"
        ;;
esac
peering_lan_maps="$(
    eval "printf 'select id, number from vlan where number in (%s);' \"\$(quote_list \$PEERING_LANS)\" | $database_cmd"
)" || bork $? "getting IDs for peering lans \"$PEERING_LANS\" from database \"$dbase_database\""
cd "${OUTPUT_DIR}" || bork $? 'entering the output directory'
if test 0 -eq $STDOUT && test 1 -eq $USE_GIT && ! test -d '.git'; then
    git init >/dev/null 2>&1 || bork $? 'initialising git repo'
fi
for vlan in $peering_lan_maps; do
    vlan_id=`printf '%s' "$vlan" | cut -d\| -f1`
    vlan_num=`printf '%s' "$vlan" | cut -d\| -f2`
    for rs in $ROUTE_SERVERS; do
        for target in $RS_TARGETS; do
            for ipv in $IP_VERSIONS; do
                if test 0 -eq $STDOUT; then
                    outfile="rs${rs}-vlan${vlan_num}-ipv${ipv}.conf"
                else
                    outfile="/dev/stdout"
                fi
                "${APP_PATH}/bin/ixptool.php" $verb -a 'router-cli.gen-server-conf' \
                  -p vlanid=${vlan_id},target=${target},proto=${ipv} \
                  --config="${CONF_DIR}/rs${rs}-vlan${vlan_num}-ipv${ipv}.conf" \
                  >"$outfile" || \
                      bork $? "router-cli.gen-server-conf (rs:$rs, target:$target, vlan:$vlan, ipv:$ipv)"
                if test 1 -eq $STDOUT; then
                    printf '\n======\n'
                fi
            done
        done
    done
done
if test 0 -eq $STDOUT && test 1 -eq $USE_GIT && test -n "`git status --porcelain 2>/dev/null`"; then
    #TODO: capture stderr output for $DEBUG use below... do we care?
    #TODO: install qprint, use quoted-printable instead of base64 (more deps, less spam-score)
    now=$(date --rfc-3339=seconds 2>/dev/null) && \
        git add . >/dev/null 2>&1 && \
        git commit -m "Config-changes at $now" >/dev/null 2>&1 || \
        bork $? "git-committing config-changes"
    if test 1 -eq `git rev-list --min-parents=0 'HEAD' 2>/dev/null | wc -l` || \
        test -n "`git diff --patch-with-raw 'HEAD^' 2>/dev/null | \
                      grep -v '^\([^+-]\|--- \|+++ \|[+-]# \+Generated: \|$\)'`"; then

## plaintext 10-line context version
#        {
#            printf 'Route server config changes on ${HOSTNAME}, git-diff output:\n\n'
#            git log -p --stat -U10 --word-diff=plain 'HEAD^..HEAD' 2>/dev/null || \
#                git log -p --stat -U10 --word-diff=plain 2>/dev/null
#        } | \
#            $MAILX \
#                -a "From: IXP-Manager <root@${HOSTNAME}>" \
#                -s "Route server config changes on $HOSTNAME" $MAIL_RECIPIENTS >/dev/null 2>&1 || \
#                bork $? 'emailing config-changes'

## multipart MIME, plaintext 3-line context, html full-context version
#        boundary="`dd if=/dev/urandom bs=128 count=1 2>/dev/null | md5sum | sed -e 's/ \+.*$//'`" || \
#            bork $? 'generating multipart-mime boundary string'
#        trap_exit_code="$trap_exit_code
#test -z \"\$temp_attach_1\" || rm -f \"\$temp_attach_1\" 2>/dev/null
#test -z \"\$temp_attach_2\" || rm -f \"\$temp_attach_2\" 2>/dev/null"
#        trap "$trap_exit_code" EXIT
#        temp_attach_1=`mktemp` && temp_attach_2=`mktemp` || bork $? 'creating tempfiles for emailing'
#        {
#            git log -p --stat --word-diff=plain -U3 'HEAD^..HEAD' 2>/dev/null || \
#                git log -p --stat --word-diff=plain -U3 2>/dev/null
#        } | $BASE64 >"$temp_attach_1" || \
#            bork "creating 3-line plaintext email output to \"$temp_attach_1\""
#        {
#            git log -p --stat --color-words -U9999 'HEAD^..HEAD' 2>/dev/null || \
#                git log -p --stat --color-words -U9999 2>/dev/null
#        } | eval "`test -z "$GEN_EMAIL_NICE" || printf 'nice -n %s ' "$GEN_EMAIL_NICE"`$ANSI2HTML" | \
#            $BASE64 >"$temp_attach_2" || \
#            bork "creating full-context html email output to \"$temp_attach_2\""
#        {
#            printf 'This is a multipart message in MIME format.\n\n'
#            printf 'Attached are route-server config changes on ${HOSTNAME}, git-diff output:\n'
#            printf ' * plaintext word-diff with 3-line context\n'
#            printf ' * html color-word-diff with full-file context\n'
#            cat <<EOF
#
#--$boundary
#Content-Type: text/plain; charset=utf-8
#Content-Transfer-Encoding: base64
#Content-Disposition: attachment; filename="plaintext-word-diff-3line-context.diff"
#
#EOF
#            cat "$temp_attach_1"
#            cat <<EOF
#
#--$boundary
#Content-Type: text/html; charset=utf-8
#Content-Transfer-Encoding: base64
#Content-Disposition: attachment; filename="html-color-word-diff-full-context.html"
#
#EOF
#            cat "$temp_attach_2"
#            cat <<EOF
#
#--${boundary}--
#EOF
#        } | sed -e 's/\r\?$/\r/' | \
#            $MAILX \
#                -a "From: IXP-Manager <root@${HOSTNAME}>" \
#                -a "Content-Type: multipart/mixed; boundary=$boundary" \
#                -a "Content-Transfer-Encoding: 7bit" \
#                -a "MIME-Version: 1.0" \
#                -s "Route server config changes on $HOSTNAME" $MAIL_RECIPIENTS >/dev/null 2>&1 || \
#                bork $? 'emailing config-changes'

## MIME, html 1-line context version
        trap_exit_code="$trap_exit_code
test -z \"\$temp_attach\" || rm -f \"\$temp_attach\" 2>/dev/null"
        trap "$trap_exit_code" EXIT
        temp_attach=`mktemp` || bork $? 'creating tempfile for emailing'
        {
            git log -p --stat --color-words -U1 'HEAD^..HEAD' 2>/dev/null || \
                git log -p --stat --color-words -U1 2>/dev/null
        } | eval "`test -z "$GEN_EMAIL_NICE" || printf 'nice -n %s ' "$GEN_EMAIL_NICE"`$ANSI2HTML" | \
            $BASE64 | sed -e 's/\r\?$/\r/' >"$temp_attach" || \
            bork "generating 1-line-context html email output to \"$temp_attach\""
        cat "$temp_attach" | \
            $MAILX \
                -a "From: IXP-Manager <root@${HOSTNAME}>" \
                -a "Content-Type: text/html; charset=utf-8" \
                -a "Content-Transfer-Encoding: base64" \
                -a "MIME-Version: 1.0" \
                -s "Route server config changes on $HOSTNAME" $MAIL_RECIPIENTS >/dev/null 2>&1 || \
                bork $? 'emailing config-changes'
    fi
fi
