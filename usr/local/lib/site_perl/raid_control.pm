## ######### PROJECT NAME : ##########
##
## raid_control.pm
##
## ######### PROJECT DESCRIPTION : ###
##
## Module de controle de la présence et de l'état des disques physiques
##
## ###################################

package raid_control;

use strict;
use Data::Dumper;
use Lib_Raid_Rpc;
use lib_raid_plugins::lib_raid_codes;
use Objet_Alerte;    # Objet d envoie d email Intellique

use POSIX('strftime');

use Sys::Hostname;

# Chemin du fichier de configuration
my $control_conf = "/etc/storiq/control.conf";

my %code_nagios = (
    4  => 'UNKNOWN',
    3  => 'CRITICAL',
    2  => 'WARNING',
    1  => 'INFO',
    0  => 'OK',
    -1 => 'UNKNOWN',
);

## ###################################
## Sortie nagios
sub formatage_sortie_nagios {
    my $list = shift;

    # Je boucle sur chaque etat nagios possible
    my $message;
    my $maxlevel = 0;
    foreach my $level ( 3, 2, 1, 4 ) {

        # Un ou plusieurs elements sont dans l'etat $i
        if ( defined $list->[$level] ) {

            $maxlevel = $level if ( $level > $maxlevel );

            foreach my $element ( @{ $list->[$level] } ) {
                $message .=
                  $code_nagios{$level} . ": " . $element->{ctl} . " : ";
                $message .= $element->{port} . " : " if ( $element->{port} );
                $message .= $element->{message} . "\n";
            }
        }
    }

    chomp $message;
    return $maxlevel, $message if $message;

    # Tout va bien
    return 0, "OK";
}

## ###################################
## Envoie alerte

sub formatage_sortie_alerte {
    my ( $logger, $list ) = @_;

    my $max_level;
    my $max_error = 0;
    my $msg_mail;
    my %retour;

    # function to call according to severity level
    my @logfunc = (
        sub { $logger->info( $_[0] ) },
        sub { $logger->info( $_[0] ) },
        sub { $logger->warn( $_[0] ) },
        sub { $logger->error( $_[0] ) },
        sub { $logger->error( $_[0] ) },
    );

    my $hostname = hostname();
    my $serial   = "";
    if ( open( my $serialnumf, '<', "/usr/share/storiq/SerialNumber" ) ) {
        while (<$serialnumf>) {
            $serial .= $_;
        }
        close $serialnumf;
        chomp $serial;
    }

    my ( $err, $alert ) = new Objet_Alerte( "alerte_raid", $logger );
    return ( $err, $alert ) if ($err);

    # Je boucle sur chaque etat nagios possible
    foreach my $level ( 3, 2, 1, 4 ) {

        # print "lvel $level\n";
        # Un ou plusieurs elements sont dans l'etat $i
        if ( defined $list->[$level] ) {
            $max_level = $level unless ( defined $max_level );

            foreach my $element ( @{ $list->[$level] } ) {
                $msg_mail .= msg_mail($element);
                my $msg = msg_snmp($element);

                $logfunc[$level]->($msg);
                my ( $err2, $send ) =
                  envoie_snmp( $alert, $level, $code_nagios{$level}, $hostname,
                    $serial, $msg );

                $max_error = $err2 if ( $max_error < $err2 );
                push @{ $retour{$err2} }, @{$send};
            }
        }
    }

    if ( defined $max_level ) {
        chomp $msg_mail;

        my ( $err2, $send ) = envoie_mail( $alert, $code_nagios{$max_level},
            $hostname, $serial, $msg_mail );

        $max_error = $err2 if ( $max_error < $err2 );

        if ( ref $send eq "ARRAY" ) {
            push @{ $retour{$err2} }, @{$send};
        } else {
            push @{ $retour{$err2} }, $send;
        }

        return $max_error, $retour{$max_error};
    }

    $logger->info( $code_nagios{"0"} );
    return $alert->send(
        [
            [ "sujet",      $code_nagios{"0"}, $hostname, $serial ],
            [ "message_ok", $hostname,         $serial ]
        ],
        [ "4.6.0", "OCTET_STRING", "0", "message_ok", $hostname, $serial ]
    );
}

sub envoie_mail {
    my ( $alert, $code, $hostname, $serial, $msg_mail ) = @_;

    return $alert->send(
        [
            [ "sujet",   $code,     $hostname, $serial ],
            [ "message", $hostname, $serial,   $msg_mail ]
        ],
        undef
    );
}

sub envoie_snmp {
    my ( $alert, $level, $code, $hostname, $serial, $msg ) = @_;

    return $alert->send(
        undef,
        [
            "4.6.3", "OCTET_STRING", $level,  "message",
            $code,   $hostname,      $serial, $msg
        ]
    );
}

## ###################################
## Controle les elements

sub control_parts {
    my $logger = shift;
    my %control;

    if ( $_[0] ) {
        $control{ $_[0] } = "";
        $control{ $_[0] } = $_[1] if ( $_[1] );
    } else {

        #Objet Conf
        my ( $err, $conf ) = new Objet_Conf( $control_conf, $logger );
        return ( 3, "ERROR: creating Objet_Conf: $conf" ) if $err;

        my ( $err2, $keys ) = $conf->get_key();
        return ( 3, "ERROR: problem reading keys: " . $keys ) if $err2;

        foreach my $ctl ( @{$keys} ) {
            my ( $err3, $ref ) = $conf->get_value($ctl);
            return ( 3, "ERROR: proble reading values: " . $ref )
              if $err3;

            $control{$ctl} = $ref;
        }
    }

    return 3, "ERROR: Nothing to control in the configuration file.\n"
      unless (%control);

    my @list_retour;
    my $all_ctl_info = Lib_Raid_Rpc::get_all_info();

    my $spacecritical = 97;
    my $spacewarning  = 90;
    my $spaceinfo     = 80;

    foreach my $ctl ( keys %control ) {

        # space testing
        if ( $ctl =~ /space(.*)/ ) {

            $spacecritical = int( $control{$ctl} )
              if ( $1 =~ /critical/ );
            $spacewarning = int( $control{$ctl} )
              if ( $1 =~ /warning/ );
            $spaceinfo = int( $control{$ctl} )
              if ( $1 =~ /info/ );

            next;
        }

        unless ( exists $all_ctl_info->{$ctl} ) {
            push @{ $list_retour[3] },
              {
                ctl     => $ctl,
                port    => undef,
                message => "ERROR: Controller '$ctl' doesn't exist.",
              };
        }
    }

    foreach my $ctl ( keys %control ) {

        # skip space testing
        next if $ctl =~ /space_/;

        # global controller status
        my $controllerstatus = $all_ctl_info->{$ctl}{status};

        # control disks
        my @disks = grep { /d\d+/ } split ' ', $control{$ctl};

        foreach my $disk (@disks) {

            # test smart (useless, no data)
            if (
                defined $all_ctl_info->{$ctl}->{drives}->{$disk}
                ->{'smartstatus'} )
            {
                my $level = 0;
                $level = 2
                  unless $all_ctl_info->{$ctl}->{drives}->{$disk}
                      ->{'smartstatus'} =~ /PASSED/;
                push @{ $list_retour[$level] },
                  {
                    ctl     => $ctl,
                    port    => $disk,
                    message => 'Smart status: '
                      . $all_ctl_info->{$ctl}->{drives}->{$disk}
                      ->{'smartstatus'},
                  };
            }

            # disk status
            my $diskstatus =
              $all_ctl_info->{$ctl}->{drives}->{$disk}->{'status'};

            if ( defined $diskstatus ) {
                my $level = 0;
                $level = 3 if ( $diskstatus != 0 );
                push @{ $list_retour[$level] },
                  {
                    ctl     => $ctl,
                    port    => $disk,
                    message => 'Status: '
                      . lib_raid_codes::get_drive_state_string($diskstatus),
                  };

            } else {
                push @{ $list_retour[3] },
                  {
                    ctl     => $ctl,
                    port    => $disk,
                    message => 'ERROR: missing drive.',
                  };
            }
        }

        # control arrays
        my @arrays = grep { /^a\d+/ } split ' ', $control{$ctl};

        foreach my $array (@arrays) {
            my $arraystatus = $all_ctl_info->{$ctl}{arrays}{$array}{status};

            if ( defined $arraystatus ) {

                # default : OK
                my $level = 0;

                # critical if not Ok
                $level = 3
                  if ( $arraystatus > 0 );

                # warning (reconfigure, init-paused, migration)
                $level = 2
                  if ( grep { $arraystatus == $_ } ( 7, 9, 11 ) );

                # info (verify, testing, charging)
                $level = 1
                  if ( grep { $arraystatus == $_ } ( 4, 8, 13 ) );

                push @{ $list_retour[$level] }, {
                    ctl     => $ctl,
                    port    => $array,
                    message => 'Status: '
                      . lib_raid_codes::get_state_string($arraystatus),

                };
            } else {
                push @{ $list_retour[2] },
                  {
                    ctl     => $ctl,
                    port    => $array,
                    message => 'ERROR: Status undefined.',
                  }

            }

        }
    }

    # check available space
    my %filesystems = check_space();

    foreach my $device ( keys %filesystems ) {

        if ( $filesystems{$device}->{percent} > $spacecritical ) {
            push @{ $list_retour[3] },
              {
                ctl  => $device,
                port => $filesystems{$device}->{mountpoint},
                message =>
"space critically low, $filesystems{$device}->{percent} % full.",
              };
            next;
        }

        if ( $filesystems{$device}->{percent} > $spacewarning ) {
            push @{ $list_retour[2] },
              {
                ctl  => $device,
                port => $filesystems{$device}->{mountpoint},
                message =>
                  "space low, $filesystems{$device}->{percent} % full.",
              };
            next;
        }

        if ( $filesystems{$device}->{percent} > $spaceinfo ) {
            push @{ $list_retour[1] },
              {
                ctl  => $device,
                port => $filesystems{$device}->{mountpoint},
                message =>
                  "space running low, $filesystems{$device}->{percent} % full.",
              };
            next;
        }
    }

    return 0, @list_retour;
}

sub control {
    my $logger = shift;
    my $format = shift;

    # Si l'objet logger est absent, je le crée.
    if ( !$logger ) {
        undef, $logger = new Objet_Logger();
        $logger->debug("control : $logger parametre is missing");
    }

    # Verification de l'integrite de l'objet Logger recu
    unless ( ref($logger) eq "Objet_Logger" ) {
        undef, $logger = new Objet_Logger();
        $logger->debug("control : $logger isn't an Objet_Logger");
    }

    my ( $etat, @list_retour ) = control_parts($logger);
    return ( $etat, @list_retour ) if ($etat);

    if ( $format eq "nagios" ) {
        return formatage_sortie_nagios( \@list_retour );
    }

    return formatage_sortie_alerte( $logger, \@list_retour );
}

# Test l'envoie d'email et de trap SNMP et sort
sub test_alert {
    my $logger = shift;

    # Si l'objet logger est absent, je le crée.
    if ( !$logger ) {
        undef, $logger = new Objet_Logger();
        $logger->debug("test_alert : $logger parametre is missing.");
    }

    # Verification de l'integrite de l'objet Logger recu
    unless ( ref($logger) eq "Objet_Logger" ) {
        undef, $logger = new Objet_Logger();
        $logger->debug("test_alert : $logger isn't an Objet_Logger");
    }

    my ( $err, $alert ) = new Objet_Alerte( "alerte_raid", $logger );
    return ( $err, $alert ) if ($err);

    my $hostname = hostname();
    my $serial   = "";
    if ( open( my $serialfile, '<', "/usr/share/storiq/SerialNumber" ) ) {
        while (<$serialfile>) {
            $serial .= $_;
        }
        close $serialfile;
        chomp $serial;
    }

    $logger->info("TEST");
    return $alert->send(
        [
            [ "sujet",        "TEST",    $hostname, $serial ],
            [ "message_test", $hostname, $serial ]
        ],
        [ "4.6.222", "OCTET_STRING", "0", "message_test", $hostname, $serial ]
    );
}

# Fichier de conf comprenant tout ce qui est controlable
sub create_conf_file {
    my $logger = shift;

    # Si l'objet logger est absent, je le crée.
    if ( !$logger ) {
        undef, $logger = new Objet_Logger();
        $logger->debug("create_conf_file : $logger parametre is missing.");
    }

    # Verification de l'integrite de l'objet Logger recu
    unless ( ref($logger) eq "Objet_Logger" ) {
        undef, $logger = new Objet_Logger();
        $logger->debug("create_conf_file : $logger isn't an Objet_Logger");
    }

    my %configuration;

    my $all_ctl_info = Lib_Raid_Rpc::get_all_info();
    foreach my $ctl ( keys %$all_ctl_info ) {

        # skip if no arrays or drives
        my @arrays = keys %{ $all_ctl_info->{$ctl}->{arrays} };
        my @drives = keys %{ $all_ctl_info->{$ctl}->{drives} };

        next
          if (  scalar(@arrays) == 0
            and scalar(@drives) == 0 );

        $configuration{$ctl} = join ' ', @arrays;

        # next if ( $ctl eq "mdm" );
        next if ( $ctl =~ m/^lvm/ );

        # skip drives not in arrays or spares : inarray != -1
        foreach
          my $drive ( sort { ( $a =~ /d(\d+)/ )[0] <=> ( $b =~ /d(\d+)/ )[0] }
            @drives )
        {
            $configuration{$ctl} .= " $drive"
              if ( $all_ctl_info->{$ctl}{drives}{inarray} != -1 );
        }
    }

    foreach ( sort keys %configuration ) {
        print "$_ = " . $configuration{$_} . "\n";
    }

    return 0, "";
}

sub msg_mail {
    my $element = shift;
    my $msg     = "Details :\n";
    $msg .= "    Date : " . strftime( "%Y/%m/%d %X", localtime ) . "\n";
    $msg .= "    Controller : " . $element->{ctl} . "\n";
    $msg .= "    Element : " . $element->{port} . "\n"
      if ( $element->{port} );
    $msg .= "    Information : " . $element->{message} . "\n\n";

    return $msg;
}

sub check_space {
    my %filesystems;

    my @df = qx(/bin/df -l);
    shift @df;

    foreach my $line (@df) {
        next if ( $line =~ /tmpfs/ or $line =~ /udev/ );

        my ( $device, $blocks, $used, $avail, $percent, $mountpoint ) =
          split /\s+/, $line;

        $percent =~ s/%//g;

        $filesystems{$device} = {
            blocks     => $blocks,
            used       => $used,
            avail      => $avail,
            percent    => $percent,
            mountpoint => $mountpoint,
        };
    }

    return %filesystems;
}

sub msg_snmp {
    my $element = shift;
    my $msg .= $element->{ctl} . " : ";
    $msg .= $element->{port} . " : " if ( $element->{port} );
    $msg .= $element->{message};
    return $msg;
}

1;
