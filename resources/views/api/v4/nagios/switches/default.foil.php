#
# This file contains Nagios configuration for production switches
#
# WARNING: this file is automatically generated using the
#   api/v4/nagios/switches/{infraid} API call to IXP Manager.
#
# Any local changes made to this script will be lost.
#
# See: http://docs.ixpmanager.org/features/nagios/
#
# You should not need to edit these files - instead use your own custom skins. If
# you can't effect the changes you need with skinning, consider posting to the mailing
# list to see if it can be achieved / incorporated.
#
# Infrastructure id: <?= $t->infra->getId() ?>; name: <?= $t->infra->getName() ?>.
#
# Generated: <?= date( 'Y-m-d H:i:s' ) . "\n" ?>
#
# The following objects are used by inheritance here and need to be defined by your own configuration:
#
# 1. Hose definition:    <?= $t->host_definition ?>;
#
# You would create these yourself by creating a configuration file containing something like:
#
# define host {
#     name                    <?= $t->host_definition ?>

#     check_command                   check-host-alive
#     max_check_attempts              3               ; number of not 'UP' checks to register as hard
#     check_interval                  5               ; time between checks
#     retry_interval                  1               ; time between checks if host is not 'UP'
#     check_period                    24x7
#     notification_interval           60
#     notification_period             24x7
#     notification_options            u,d,r
#     contact_groups                  admins
#     register                        0
# }


<?php

    // some vars for later:
    $locations      = [];
    $vendors        = [];
    $all            = [];

    /** @var Entities\Switcher $s */
    foreach( $t->switches as $s ):

        if( !$s->getActive() ) {
            echo "\n\n## Skipping {$s->getHostname()} as it is disabled\n\n";
            continue;
        }

        $vendors[ $s->getVendor()->getShortname() ]['switches'][]                = $s->getHostname();
        $vendors[ $s->getVendor()->getShortname() ]['bymodel'][$s->getModel()][] = $s->getHostname();

        $locations[ $s->getCabinet()->getLocation()->getShortname() ][] = $s->getHostname();
        $all[] = $s->getHostname();

?>

#
# <?= $s->getName() ?> - <?= $s->getCabinet()->getCololocation() ?>, <?= $s->getCabinet()->getLocation()->getName() ?>.
#

define host {
    use                     <?= $t->host_definition ?>

    host_name               <?= $s->getHostname() ?>

    alias                   <?= $s->getName() ?>

    address                 <?= $s->getIpv4addr() ?>

}

<?php endforeach; ?>



###############################################################################################
###############################################################################################
###############################################################################################
###############################################################################################
###############################################################################################
###############################################################################################


###############################################################################################
###
### Group: by location
###
###
###


<?php foreach( $locations as $name => $switches ):
    asort( $switches ); ?>

define hostgroup {
    hostgroup_name          ixp-switches-infraid-<?= $t->infra->getId() ?>-<?= strtolower( $name ) ?>

    alias                   IXP Switches at <?= $name ?> on <?= $t->infra->getName() ?>

    members                 <?= $t->softwrap( $switches, 1, ', ', ', \\', 28 ) ?>

}

<?php endforeach; ?>


###############################################################################################
###
### Group: by infrastructure (all)
###
###
###

<?php asort( $all ); ?>

define hostgroup {
    hostgroup_name          ixp-production-switches-infraid-<?= $t->infra->getId() ?>

    alias                   IXP Production Switches on <?= $t->infra->getName() ?> (all on infraid-<?= $t->infra->getId() ?>)
    members                 <?= $t->softwrap( $all, 1, ', ', ', \\', 28 ) ?>

}


###############################################################################################
###
### Group: by vendor and model
###
###
###

<?php foreach( $vendors as $shortname => $v ):
    asort( $v) ; ?>


###############################################################################################
### <?= $shortname ?>


define hostgroup {
    hostgroup_name          ixp-switches-infraid-<?= $t->infra->getId() ?>-<?= strtolower( $shortname ) ?>

    alias                   IXP <?= $shortname ?> Switches
    members                 <?= $t->softwrap( $v['switches'], 1, ', ', ', \\', 28 ) ?>

}

    <?php foreach( $v['bymodel'] as $model => $modelsws ):
            asort( $modelsws ); ?>

define hostgroup {
    hostgroup_name          ixp-switches-infraid-<?= $t->infra->getId() ?>-<?= strtolower( $shortname ) ?>-<?= preg_replace( "/[^0-9a-z\-]/", "", strtolower( $model ) ) ?>

    alias                   IXP <?= $shortname ?> <?= $model ?> Switches
    members                 <?= $t->softwrap( $modelsws, 1, ', ', ', \\', 28 ) ?>

}

    <?php endforeach; ?>

<?php endforeach; ?>


