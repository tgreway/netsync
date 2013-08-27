#! /usr/bin/perl

use autodie;
use diagnostics;
use strict;
use warnings;

use feature 'say';
use feature 'switch';

use Data::Dumper; #XXX
use DBI;
use File::Basename;
use Getopt::Std;
use Net::DNS;
use POSIX;
use Regexp::Common;
use Scalar::Util 'blessed';
use SNMP;
use SNMP::Info;
use Text::CSV;

use Toolbox::Configurator;
use Toolbox::FileManager;
use Toolbox::UserInterface;


our (%options,%settings,$VERSION);


BEGIN {
    $VERSION = '0.0';
    $options{'options'}   = 'c:p:D:d:';
    $options{'arguments'} = '[nodes]';
    
    $Data::Dumper::Sortkeys = 1; #XXX
    $Getopt::Std::STANDARD_HELP_VERSION = 1;
    $| = 1;
    
    #SNMP::initMib(); #XXX
    SNMP::loadModules('IF-MIB');
    SNMP::loadModules('ENTITY-MIB');
    
    SNMP::loadModules('CISCO-STACK-MIB');             # Cisco
    SNMP::loadModules('FOUNDRY-SN-AGENT-MIB');        # Brocade
    SNMP::loadModules('FOUNDRY-SN-SWITCH-GROUP-MIB'); # Brocade
    SNMP::loadModules('HP-SN-AGENT-MIB');             # HP
    SNMP::loadModules('SEMI-MIB');                    # HP
}


sub VERSION_MESSAGE {
    say ((basename $0).' v'.$VERSION);
    say 'Perl v'.$];
    
    #vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv#
    
    say 'DBI v'.$DBI::VERSION;
    say 'File::Basename v'.$File::Basename::VERSION;
    say 'Getopt::Std v'.$Getopt::Std::VERSION;
    say 'Net::DNS v'.$Net::DNS::VERSION;
    say 'POSIX v'.$POSIX::VERSION;
    say 'Regexp::Common v'.$Regexp::Common::VERSION;
    say 'Scalar::Util v'.$Scalar::Util::VERSION;
    say 'SNMP v'.$SNMP::VERSION;
    say 'SNMP::Info v'.$SNMP::Info::VERSION;
    say 'Text::CSV v'.$Text::CSV::VERSION;
}


sub HELP_MESSAGE {
    my $opts = $options{'options'};
    $opts =~ s/[:]+//g;
    say ((basename $0).' [-'.$opts.'] '.$options{'arguments'});
    say '  -h        Help. Print usage and options.';
    say '  -q        Quiet. Print nothing.';
    say '  -v        Verbose. Print everything.';
    say '  -V        Version. Print build information.';
    
    #vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv#
    
    say '  -c .ini     Specify a configuration file to use.';
    say '  -p #        Probe. There are 2 probe levels:';
    say '                  1: Probe the network for active nodes.';
    say '                  2: Probe the database for those nodes.';
    say '  -D pattern  Use DNS to retrieve a list of hosts matching the pattern.';
    say '  -d .csv     Specify an RFC4180-compliant database file to use.';
    say '  nodes       Specify an RFC1035-compliant network node list to use.';
}


INIT {
    my %opts;
    $options{'options'} .= 'hqvV';
    HELP_MESSAGE    and exit 1 unless getopts ($options{'options'},\%opts);
    HELP_MESSAGE    and exit if $opts{'h'};
    VERSION_MESSAGE and exit if $opts{'V'};
    $options{'quiet'}   = $opts{'q'} // 0; #/#XXX
    $options{'verbose'} = $opts{'v'} // 0; #/#XXX
    $options{'verbose'} = --$options{'quiet'} if $options{'verbose'} and $options{'quiet'};
    
    #vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv#
    
    $options{'conf_file'} = $opts{'c'} // 'etc/'.(basename $0).'.ini'; #'#XXX
    $options{'probe_level'} = $opts{'p'} // 0; #/#XXX
    unless ($options{'probe_level'} =~ /^[0-2]$/) {
        say 'There are only 2 probe levels:';
        say '    1: Probe the network for active nodes.';
        say '    2: Probe the database for those nodes.';
        say 'Each level includes all previous levels.';
        exit 1;
    }
    $options{'use_DNS'} = $opts{'D'} // 0; #/#XXX
    $options{'use_CSV'} = $opts{'d'} // 0; #/#XXX
    $options{'node_list'} = $ARGV[0] // '-'; #/#XXX
}




sub validate {
    warn 'too many arguments' if @_ > 0;
    
    my $required = [
        'Table',
        'DeviceField',
        'InterfaceField',
        'InfoFields',
    ];
    foreach (@$required) {
        die 'missing information ('.$_.')' unless defined $settings{$_};
    }
}




################################################################################




sub SNMP_get1 {
    warn 'too few arguments'  if @_ < 1;
    warn 'too many arguments' if @_ > 3;
    my ($oids,$session) = @_;
    
    unless (blessed $session and $session->isa('SNMP::Session')) {
        return undef if ref $session;
        ($session) = SNMP_Info $session;
        return undef unless defined $session;
    }
    
    my (@objects,@IIDs);
    foreach my $oid (@$oids) {
        my $query = SNMP::Varbind->new([$oid->[0]]);
        while (my $object = $session->getnext($query)) {
            last unless $query->tag eq $oid->[1] and not $session->{'ErrorNum'};
            last if $object =~ /^ENDOFMIBVIEW$/;
            $object =~ s/^\s*(.*?)\s*$/$1/;
            push (@IIDs,$query->iid);
            push (@objects,$object);
        }
        last if @objects != 0;
    }
    return undef if @objects == 0;
    return (\@objects,\@IIDs);
}




sub device_interfaces {
    warn 'too few arguments'  if @_ < 2;
    warn 'too many arguments' if @_ > 2;
    my ($vendor,$session) = @_;
    
    my %serial2ifName;
    {
        my %if2ifName;
        {
            my ($types) = SNMP_get1 ([['.1.3.6.1.2.1.2.2.1.3' => 'ifType']],$session); # IF-MIB
            my ($ifNames,$ifs) = SNMP_get1 ([
                ['.1.3.6.1.2.1.31.1.1.1.1' => 'ifName'],  # IF-MIB
                ['.1.3.6.1.2.1.2.2.1.2'    => 'ifDescr'], # IF-MIB
            ],$session); # IF-MIB
            foreach my $i (keys @$ifs) {
                alert 'Malformed IF-MIB results have been received.' and next unless defined $types->[$i] and defined $ifNames->[$i];
                $if2ifName{$ifs->[$i]} = $ifNames->[$i] if $types->[$i] =~ /^(?!1|24|53)[0-9]+$/;
                alert 'A foreign ifType ('.$types->[$i].') has been encountered on interface '.$ifNames->[$i] if $types->[$i] =~ /^(?!1|6|24|53)[0-9]+$/;
            }
        }
        
        my @serials;
        {
            my ($serials) = SNMP_get1 ([['.1.3.6.1.2.1.47.1.1.1.1.11' => 'entPhysicalSerialNum']],$session); # ENTITY-MIB
            if (defined $serials) {
                my ($classes) = SNMP_get1 ([['.1.3.6.1.2.1.47.1.1.1.1.5' => 'entPhysicalClass']],$session);  # ENTITY-MIB
                foreach my $i (keys @$classes) {
                    push (@serials,$serials->[$i]) if $classes->[$i] =~ /3/;
                }
            }
        }
        unless (@serials > 0) {
            given ($vendor) {
                when ('cisco') {
                    my ($serials) = SNMP_get1 ([
                        ['.1.3.6.1.4.1.9.5.1.3.1.1.3'  => 'moduleSerialNumber'],       # CISCO-STACK-MIB
                        ['.1.3.6.1.4.1.9.5.1.3.1.1.26' => 'moduleSerialNumberString'], # CISCO-STACK-MIB
                    ],$session);
                    @serials = @$serials;
                }
                when ('foundry') {
                    my ($serials) = SNMP_get1 ([
                        ['.1.3.6.1.4.1.1991.1.1.1.4.1.1.2' => 'snChasUnitSerNum'], # FOUNDRY-SN-AGENT-MIB?
                        ['.1.3.6.1.4.1.1991.1.1.1.1.2'     => 'snChasSerNum'],     # FOUNDRY-SN-AGENT-MIB (stackless)
                    ],$session);
                    @serials = @$serials;
                }
                when ('hp') {
                    my ($serials) = SNMP_get1 ([
                        ['.1.3.6.1.4.1.11.2.36.1.1.5.1.1.10'   => 'hpHttpMgDeviceSerialNumber'], # SEMI-MIB
                        ['.1.3.6.1.4.1.11.2.36.1.1.2.9'        => 'hpHttpMgSerialNumber'],       # SEMI-MIB
                        ['.1.3.6.1.4.1.11.2.3.7.11.12.1.1.1.2' => 'snChasSerNum'],               # HP-SN-AGENT-MIB (stackless?)
                    ],$session);
                    @serials = @$serials;
                }
                default {
                    alert 'Serial retrieval attempted on an unsupported device vendor ('.$vendor.')';
                }
            }
            if (@serials == 0) {
                alert 'No serials could be found for a '.$vendor.' device.';
                return undef;
            }
        }
        
        if (@serials == 1) {
            push (@{$serial2ifName{$serials[0]}},$_) foreach values %if2ifName;
        }
        else {
            my %ifName2serial;
            given ($vendor) {
                when ('cisco') {
                    my %if2serial;
                    {
                        my ($port2if) = SNMP_get1 ([['.1.3.6.1.4.1.9.5.1.4.1.1.11' => 'portIfIndex']],$session); # CISCO-STACK-MIB
                        my @port2serial;
                        {
                            my ($port2module) = SNMP_get1 ([['.1.3.6.1.4.1.9.5.1.4.1.1.1'  => 'portModuleIndex']],$session); # CISCO-STACK-MIB
                            my %module2serial;
                            {
                                my ($serials,$modules) = SNMP_get1 ([
                                    ['.1.3.6.1.4.1.9.5.1.3.1.1.3'  => 'moduleSerialNumber'],       # CISCO-STACK-MIB
                                    ['.1.3.6.1.4.1.9.5.1.3.1.1.26' => 'moduleSerialNumberString'], # CISCO-STACK-MIB
                                ],$session);
                                @module2serial{@$modules} = @$serials;
                            }
                            push (@port2serial,$module2serial{$_}) foreach @$port2module;
                        }
                        @if2serial{@$port2if} = @port2serial;
                    }
                    $ifName2serial{$if2ifName{$_}} = $if2serial{$_} foreach keys %if2ifName;
                }
                when ('foundry') {
                    my %if2serial;
                    {
                        my ($port2if) = SNMP_get1 ([['.1.3.6.1.4.1.1991.1.1.3.3.1.1.38' => 'snSwPortIfIndex']],$session); # FOUNDRY-SN-SWITCH-GROUP-MIB
                        my @port2serial;
                        {
                            my ($port2umi) = SNMP_get1 ([['.1.3.6.1.4.1.1991.1.1.3.3.1.1.39' => 'snSwPortDescr']],$session); # FOUNDRY-SN-SWITCH-GROUP-MIB
                            my %module2serial;
                            {
                                my ($serials,$modules) = SNMP_get1 ([['.1.3.6.1.4.1.1991.1.1.1.4.1.1.2' => 'snChasUnitSerNum']],$session); # FOUNDRY-SN-AGENT-MIB?
                                @module2serial{@$modules} = @$serials;
                            }
                            foreach (@$port2umi) {
                                push (@port2serial,$module2serial{$+{'unit'}}) if m{^(?<unit>[0-9]+)(/[0-9]+)+$};
                            }
                        }
                        @if2serial{@$port2if} = @port2serial;
                    }
                    $ifName2serial{$if2ifName{$_}} = $if2serial{$_} foreach keys %if2ifName;
                }
                default {
                    alert 'Interface mapping attempted on an unsupported device vendor ('.$vendor.')';
                }
            }
            foreach my $ifName (keys %ifName2serial) {
                push (@{$serial2ifName{$ifName2serial{$ifName}}},$ifName) if defined $ifName2serial{$ifName};
            }
        }
    }
    
    return %serial2ifName;
}




sub initialize_node {
    warn 'too few arguments'  if @_ < 1;
    warn 'too many arguments' if @_ > 1;
    my ($node) = @_;
    
    return undef unless defined $node->{'session'} and defined $node->{'info'};
    my %serial2ifName = device_interfaces ($node->{'info'}->vendor,$node->{'session'});
    my @serials = keys %serial2ifName;
    return @serials unless @serials > 0;
    foreach my $serial (@serials) {
        initialize_device ($node,$serial,$serial2ifName{$serial});
    }
    return @serials;
}




sub dump_node {
    warn 'too few arguments' if @_ < 1;
    my (@nodes) = @_;
    
    foreach my $node (@nodes) {
        if (defined $node->{'ip'} and defined $node->{'hostname'}) {
            say $node->{'ip'}.' ('.$node->{'hostname'}.')';
        }
        else {
            alert 'A malformed node has been detected.';
        }
        
        my $device_count = 0;
        if (defined $node->{'devices'}) {
            $device_count = scalar keys %{$node->{'devices'}};
            
            my ($recognized_device_count,$interface_count,$recognized_interface_count) = (0,0,0);
            foreach my $serial (keys %{$node->{'devices'}}) {
                my $device = $node->{'devices'}{$serial};
                ++$recognized_device_count if $device->{'recognized'};
                next unless defined $device->{'interfaces'};
                $interface_count += scalar keys %{$device->{'interfaces'}};
                foreach my $ifName (keys %{$device->{'interfaces'}}) {
                    my $interface = $device->{'interfaces'}{$ifName};
                    ++$recognized_interface_count if $interface->{'recognized'};
                }
            }
            print ((' 'x$settings{'Indent'}).$device_count.' device');
            print 's' if $device_count != 1;
            print ' ('.$recognized_device_count.' recognized)' if $recognized_device_count > 0;
            print "\n";
            print ((' 'x$settings{'Indent'}).$interface_count.' interface');
            print 's' if $interface_count != 1;
            print ' ('.$recognized_interface_count.' recognized)' if $recognized_interface_count > 0;
            print "\n";
        }
        else {
            alert 'A deviceless node ('.$node->{'hostname'}.') has been detected.';
        }
        
        if (defined $node->{'info'}) {
            my $info = $node->{'info'};
            if ($device_count == 1) {
                #say ((' 'x$settings{'Indent'}).$info->class); #XXX
                say ((' 'x$settings{'Indent'}).$info->vendor.' '.$info->model);
                say ((' 'x$settings{'Indent'}).$info->serial);
            }
        }
        else {
            alert 'An informationless node ('.$node->{'hostname'}.') has been detected.';
        }
    }
    say scalar (@nodes).' nodes' if @nodes > 1;
}




sub initialize_device {
    warn 'too few arguments'  if @_ < 2;
    warn 'too many arguments' if @_ > 3;
    my ($node,$serial,$ifNames) = @_;
    $ifNames //= []; #/#XXX
    
    $serial = uc $serial;
    $node->{'devices'}{$serial}{'serial'} = $serial;
    my $device = $node->{'devices'}{$serial};
    $device->{'node'} = $node;
    foreach my $ifName (@$ifNames) {
        initialize_interface ($device,$ifName);
    }
    $device->{'recognized'} = 0;
    return $device;
}




sub dump_device {
    warn 'too few arguments' if @_ < 1;
    my (@devices) = @_;
    
    foreach my $device (@devices) {
        if (defined $device->{'serial'} and defined $device->{'node'}) {
            print $device->{'serial'};
            print ' at '.$device->{'node'}{'ip'};
            print ' ('.$device->{'node'}{'hostname'}.')';
        }
        else {
            alert 'A malformed device has been detected.';
        }
        
        print "\n"; #say ' - '.($device->{'recognized'}) ? 'recognized' : 'unrecognized' if defined $device->{'recognized'}; #XXX
        
        if (defined $device->{'interfaces'}) {
            my $interface_count = scalar keys %{$device->{'interfaces'}};
            my $recognized_interface_count = 0;
            foreach my $ifName (keys %{$device->{'interfaces'}}) {
                my $interface = $device->{'interfaces'}{$ifName};
                ++$recognized_interface_count if $interface->{'recognized'};
            }
            print ((' 'x$settings{'Indent'}).$interface_count.' interface');
            print 's' if $interface_count != 1;
            say ' ('.$recognized_interface_count.' recognized)';
        }
    }
    say scalar (@devices).' devices' if @devices > 1;
}




sub initialize_interface { #XXX
    warn 'too few arguments'  if @_ < 2;
    warn 'too many arguments' if @_ > 3;
    my ($device,$ifName,$fields) = @_;
    $fields //= {}; #/#XXX
    
    $device->{'interfaces'}{$ifName}{'ifName'} = $ifName;
    my $interface = $device->{'interfaces'}{$ifName};
    $interface->{'device'}     = $device;
    $interface->{'info'}{$_}   = $fields->{$_} foreach keys %$fields;
    $interface->{'recognized'} = (scalar keys %$fields > 0);
    return $interface;
}




sub dump_interface {
    warn 'too few arguments' if @_ < 1;
    my (@interfaces) = @_;
    
    foreach my $interface (@interfaces) {
        if (defined $interface->{'ifName'} and defined $interface->{'device'} and defined $interface->{'device'}{'node'}) {
            print $interface->{'ifName'};
            print ' on '.$interface->{'device'}{'serial'};
            print ' at '.$interface->{'device'}{'node'}{'ip'};
            print ' ('.$interface->{'device'}{'node'}{'hostname'}.')';
        }
        else {
            alert 'A malformed interface has been detected.'
        }
        
        print "\n"; #say ' ('.(($interface->{'recognized'}) ? 'recognized' : 'unrecognized').')' if defined $interface->{'recognized'}; #XXX
        
        if (defined $interface->{'info'}) {
            foreach my $field (sort keys %{$interface->{'info'}}) {
                say ((' 'x$settings{'Indent'}).$field.': '.$interface->{'info'}{$field});
            }
        }
    }
    say scalar (@interfaces).' interfaces' if @interfaces > 1;
}




################################################################################




sub probe {
    warn 'too few arguments' if @_ < 1;
    my (@nodes) = @_;
    
    my $serial_count = 0;
    foreach my $node (@nodes) {
        my $note = $node->{'ip'}.' ('.$node->{'hostname'}.')';
        
        my ($session,$info) = SNMP_Info $node->{'ip'};
        if (defined $info) {
            $node->{'session'} = $session;
            $node->{'info'}    = $info;
        }
        else {
            note ($settings{'NodeLog'},$note.' inactive');
            say $note.' inactive' if $options{'verbose'};
            next;
        }
        
        { # Process a newly discovered node.
            my @serials = initialize_node $node;
            note ($settings{'NodeLog'},$note.' no devices detected') and next unless @serials > 0;
            note ($settings{'NodeLog'},$note.' '.join (' ',@serials));
            $serial_count += @serials;
        }
        
        dump_node $node if $options{'verbose'};
    }
    return $serial_count;
}




sub discover {
    warn 'too many arguments' if @_ > 1;
    my ($nodes) = @_;
    $nodes //= {}; #/#XXX
    
    unless ($options{'quiet'}) {
        print 'discovering';
        print ' (using '.((defined $options{'use_DNS'}) ? 'DNS' : ($options{'node_list'} eq '-') ? 'STDIN' : $options{'node_list'}).')...';
        print (($options{'verbose'}) ? "\n" : (' 'x$settings{'NodeOrder'}).'0');
    }
    
    # Retrieve network nodes from file, pipe, or DNS (-D).
    my @zone;
    if (defined $options{'use_DNS'}) {
        my $resolver = DNS;
        $resolver->print if $options{'verbose'};
        $options{'use_DNS'} = '([^.]+)' if $options{'use_DNS'} eq 'all';
        foreach my $record ($resolver->axfr) {
            push (@zone,$record->string) if $record->name =~ /^($options{'use_DNS'})\./;
        }
    }
    else {
        if ($options{'node_list'} eq '-') {
            chomp (@zone = <>);
        }
        else {
            open (my $node_list,'<',$options{'node_list'});
            chomp (@zone = <$node_list>);
            close $node_list;
        }
    }
    
    my ($inactive_node_count,$deployed_device_count,$stack_count) = (0,0,0);
    foreach (@zone) {
        if (/^(?<host>[^.]+).*\s(?:A|AAAA)\s+(?<ip>$RE{'net'}{'IPv4'}|$RE{'net'}{'IPv6'})/) {
            $nodes->{$+{'ip'}}{'ip'} = $+{'ip'};
            my $node = $nodes->{$+{'ip'}};
            $node->{'hostname'} = $+{'host'};
            
            my $serial_count = probe $node;
            if ($serial_count < 1) {
                ++$inactive_node_count;
                delete $nodes->{$+{'ip'}};
            }
            else {
                $deployed_device_count += $serial_count;
                ++$stack_count if $serial_count > 1;
                
                note ($settings{'Probe1Cache'},$_,0,'>') if $options{'probe_level'} > 0;
                
                unless ($options{'quiet'} or $options{'verbose'}) {
                    print  "\b"x$settings{'NodeOrder'};
                    printf ('%'.$settings{'NodeOrder'}.'d',scalar keys %$nodes);
                }
            }
        }
    }
    
    unless ($options{'quiet'}) {
        my $node_count = scalar keys %$nodes;
        print $node_count if $options{'verbose'};
        print ' node';
        print 's' if $node_count > 1;
        print ' ('.$inactive_node_count.' inactive)' if $inactive_node_count > 0;
        print ', '.$deployed_device_count.' devices';
        print ' ('.$stack_count.' stacks)' if $stack_count > 0;
        print "\n";
    }
    
    return $nodes;
}




################################################################################




sub detect_conflicts {
    warn 'too few arguments'  if @_ < 2;
    warn 'too many arguments' if @_ > 2;
    my ($device,$rows) = @_;
    
    my $conflict_count = 0;
    foreach my $row (@$rows) {
        my $ifName = $row->{$settings{'InterfaceField'}};
        if (defined $device->{'interfaces'}{$ifName}) {
            my $interface = $device->{'interfaces'}{$ifName};
            
            if ($interface->{'recognized'}) {
                ++$conflict_count;
                push (@{$interface->{'conflicts'}{'duplicate'}},$row);
            }
        }
        else {
            ++$conflict_count;
            push (@{$device->{'conflicts'}{'misnamed'}},$row);
        }
    }
    return $conflict_count;
}




sub resolve_conflicts {
    warn 'too few arguments'  if @_ < 1;
    warn 'too many arguments' if @_ > 2;
    my ($nodes,$auto) = @_;
    $auto //= 0; #/#XXX
    
    foreach my $ip (sort keys %$nodes) {
        my $node = $nodes->{$ip};
        foreach my $serial (sort keys %{$node->{'devices'}}) {
            my $device = $node->{'devices'}{$serial};
            if ($device->{'recognized'}) {
                foreach my $conflict (sort keys %{$device->{'conflicts'}}) {
                    while (my $row = shift @{$device->{'conflicts'}{$conflict}}) {
                        my $ifName   = $row->{$settings{'InterfaceField'}};
                        given ($conflict) {
                            my $suffix = $serial.' at '.$ip.' ('.$node->{'hostname'}.').';
                            when ('misnamed') {
                                my $recognize = $auto;
                                unless ($auto) {
                                    my $message = 'There is an misnamed interface in the database ('.$ifName.') for '.$suffix;
                                    my @choices;
                                    push (@choices,($options{'probe_level'} > 1) ? 'Omit'    : 'Delete');
                                    push (@choices,($options{'probe_level'} > 1) ? 'Include' : 'Ignore');
                                    $recognize = (choose ($message,\@choices) eq $choices[1]);
                                }
                                if ($recognize) {
                                    my $fields = {};
                                    foreach my $field (@{$settings{'InfoFields'}}) {
                                        $fields->{$field} = $row->{$field};
                                    }
                                    initialize_interface ($device,$ifName,$fields);
                                }
                            }
                            when ('duplicate') {
                                my $interface = $device->{'interfaces'}{$ifName};
                                my $new = $auto;
                                unless ($auto) {
                                    my $message = 'There is more than one entry in the database with information for '.$ifName.' on '.$suffix;
                                    my @choices;
                                    push (@choices,'(old) ');
                                    push (@choices,'(new) ');
                                    foreach my $field (@{$settings{'InfoFields'}}) {
                                        $choices[0] .= ', ' unless $choices[0] eq '(old) ';
                                        $choices[1] .= ', ' unless $choices[1] eq '(new) ';
                                        $choices[0] .= $interface->{'info'}{$field};
                                        $choices[1] .= $row->{$field};
                                    }
                                    $new = (choose ($message,\@choices) eq $choices[1]);
                                }
                                if ($new) {
                                    $interface->{'info'}{$_} = $row->{$_} foreach @{$settings{'InfoFields'}};
                                }
                            }
                            default {
                                alert 'Resolution of an unsupported conflict ('.$conflict.') has been attempted.';
                            }
                        }
                    }
                    delete $device->{'conflicts'}{$conflict};
                }
                delete $device->{'conflicts'};
                
                foreach my $ifName (keys %{$device->{'interfaces'}}) {
                    my $interface = $device->{'interfaces'}{$ifName};
                    note ($settings{'BogeyLog'},$ip.' ('.$node->{'hostname'}.') '.$device->{'serial'}.' '.$ifName) unless $interface->{'recognized'};
                }
            }
            else {
                note ($settings{'BogeyLog'},$ip.' ('.$node->{'hostname'}.') '.$device->{'serial'});
                if ($options{'probe_level'} > 1 and not $auto) {
                    say 'A new device ('.$device->{'serial'}.') has been detected on '.$node->{'hostname'}.' that is not present in the database.';
                    if (ask 'Would you like to initialize it now?') {
                        foreach my $ifName (sort keys %{$device->{'interfaces'}}) {
                            my $interface = $device->{'interfaces'}{$ifName};
                            say 'An interface ('.$ifName.') for '.$serial.' on '.$node->{'hostname'}.' is missing information.';
                            foreach my $field (@{$settings{'InfoFields'}}) {
                                print ((' 'x$settings{'Indent'}).$field.': ');
                                $interface->{'info'}{$field} = <>;
                            }
                        }
                    }
                }
            }
        }
    }
}




sub recognize {
    warn 'too few arguments'  if @_ < 2;
    warn 'too many arguments' if @_ > 2;
    my ($nodes,$serial) = @_;
    $serial = uc $serial;
    
    my $recognized;
    foreach my $ip (keys %$nodes) {
        my $node = $nodes->{$ip};
        if (exists $node->{'devices'}{$serial}) {
            $node->{'devices'}{$serial}{'recognized'} = 1;
            $recognized = $node;
            last;
        }
    }
    return $recognized;
}




sub synchronize {
    warn 'too few arguments' if @_ < 3;
    my ($nodes,$recognized,@rows) = @_;
    
    my $conflict_count = 0;
    foreach my $row (@rows) {
        my $serial = $row->{$settings{'DeviceField'}};
        my $ifName = $row->{$settings{'InterfaceField'}};
        
        my $node = $recognized->{$serial};
        unless (defined $node) {
            $node = recognize ($nodes,$serial);
            unless (defined $node) {
                note ($settings{'DeviceLog'},$serial.' undeployed');
                say $serial.' undeployed' if $options{'verbose'};
                next;
            }
            $recognized->{$serial} = $node;
            note ($settings{'DeviceLog'},$serial.' @ '.$node->{'ip'}.' ('.$node->{'hostname'}.')'); #XXX
        }
        
        { # Detect conflicts.
            my $device = $node->{'devices'}{$serial};
            my $new_conflict_count = detect_conflicts ($device,[$row]);
            if ($new_conflict_count > 0) {
                $conflict_count += $new_conflict_count;
            }
            else {
                my $interface = $device->{'interfaces'}{$ifName};
                ++$interface->{'recognized'};
                foreach my $field (@{$settings{'InfoFields'}}) {
                    $interface->{'info'}{$field} = $row->{$field};
                }
                
                dump_interface $interface if $options{'verbose'};
            }
        }
    }
    return $conflict_count;
}




sub identify {
    warn 'too few arguments'  if @_ < 1;
    warn 'too many arguments' if @_ > 1;
    my ($nodes) = @_;
    
    my $fields = $settings{'DeviceField'}.','.$settings{'InterfaceField'};
    $fields .= ','.join (',',sort @{$settings{'InfoFields'}});
    
    unless ($options{'quiet'}) {
        print 'identifying';
        print ' (using '.($options{'use_CSV'} // get_config 'DB.DBMS').')...'; #/#XXX
        print (($options{'verbose'}) ? "\n" : (' 'x$settings{'NodeOrder'}).'0');
    }
    
    # Retrieve node interfaces from database.
    my @data;
    if (defined $options{'use_CSV'}) {
        open (my $db,'<',$options{'use_CSV'});
        
        my $parser = Text::CSV->new;
        chomp (my @fields = split (',',<$db>));
        $parser->column_names(@fields);
        
        my $removed_field_count = 0;
        foreach my $i (keys @fields) {
            $i -= $removed_field_count;
            unless ($fields =~ /(^|,)$fields[$i](,|$)/) {
                ++$removed_field_count;
                splice (@fields,$i,1);
            }
        }
        die 'incompatible database' unless @fields == scalar split (',',$fields);
        
        foreach my $row (@{$parser->getline_hr_all($db)}) {
            my $entry = {};
            $entry->{$_} = $row->{$_} foreach @fields;
            push (@data,$entry);
        }
        
        close $db;
    }
    else {
        my $db = DB;
        my $query = $db->prepare('SELECT * FROM '.$settings{'Table'}); #XXX $db->prepare('SELECT '.$fields.' FROM '.$settings{'Table'});
        $query->execute;
        @data = @{$query->fetchall_arrayref({})};
        $db->disconnect;
    }
    
    my $conflict_count = 0;
    {
        my %recognized; # $recognized{$serial} == $node
        
        foreach my $row (@data) {
            my $valid = [
                $settings{'DeviceField'},
                $settings{'InterfaceField'},
            ];
            my $invalid = 0;
            foreach my $field (@$valid) {
                ++$invalid and last unless defined $row->{$field} and $row->{$field} =~ /[\S]+/;
            }
            next if $invalid;
            
            $conflict_count += synchronize ($nodes,\%recognized,$row);
            
            unless ($options{'quiet'} or $options{'verbose'}) {
                print  "\b"x$settings{'NodeOrder'};
                printf ('%'.$settings{'NodeOrder'}.'d',scalar keys %recognized);
            }
        }
        
        unless ($options{'quiet'}) {
            print scalar keys %recognized if $options{'verbose'};
            print ' recognized';
            print ' ('.$conflict_count.' conflicts)' if $conflict_count > 0;
            print "\n";
        }
    }
    
    { # Resolve conflicts.
        my $auto = ($conflict_count > 0);
        $auto = (not ask 'Do you want to resolve conflicts now?') unless $options{'quiet'} or $conflict_count < 1;
        resolve_conflicts ($nodes,$auto);
    }
    
    if ($options{'probe_level'} > 1) {
        note ($settings{'Probe2Cache'},$fields,0,'>');
        foreach my $ip (keys %$nodes) {
            my $node = $nodes->{$ip};
            foreach my $serial (keys %{$node->{'devices'}}) {
                my $device = $node->{'devices'}{$serial};
                foreach my $ifName (keys %{$device->{'interfaces'}}) {
                    my $interface = $device->{'interfaces'}{$ifName};
                    
                    my $note = $serial.','.$ifName;
                    foreach my $field (@{$settings{'InfoFields'}}) {
                        $note .= ','.($interface->{'info'}{$field} // ''); #/#XXX
                    }
                    note ($settings{'Probe2Cache'},$note,0);
                }
            }
        }
    }
}




################################################################################




sub update {
    warn 'too few arguments'  if @_ < 1;
    warn 'too many arguments' if @_ > 1;
    my ($nodes) = @_;
    
    #XXX
}




################################################################################




sub run {
    
    # netsync discovers all active network devices listed in [nodes] or DNS (-D).
    # It uses gathered information to identify each device in a provided database.
    # Identified devices are then updated unless probing is used (see below).
    
    my $nodes;
    
    #  $nodes == {
    #              $ip => {
    #                       'devices'  => {
    #                                       $serial => {
    #                                                    'conflicts'  => { # This key exists during the identification stage only.
    #                                                                      'misnamed' => ARRAY,
    #                                                                    },
    #                                                    'interfaces' => {
    #                                                                      $ifName => {
    #                                                                                   'conflicts'  => { # This key exists during the identification stage only.
    #                                                                                                     'duplicate' => ARRAY,
    #                                                                                                   },
    #                                                                                   'device'     => $device,
    #                                                                                   'info'       => {
    #                                                                                                     $field => SCALAR,
    #                                                                                                   },
    #                                                                                   'recognized' => SCALAR,
    #                                                                                 },
    #                                                                    },
    #                                                    'node'       => $node;
    #                                                    'recognized' => SCALAR;
    #                                                  },
    #                                     },
    #                       'hostname' => SCALAR,
    #                       'info'     => SNMP::Info,
    #                       'ip'       => SCALAR,
    #                       'session'  => SNMP::Session,
    #                     },
    #            };
    
    discover $nodes;
    exit if $options{'probe_level'} == 1;
    
    # Probe Level 1:
    #     netsync executes the discovery stage only.
    #     It probes the network for active nodes (logging them appropriately),
    #     and it creates an RFC1035-compliant list of them (default: var/dns.txt).
    #     This list may then be used as input to netsync to skip inactive nodes later.
    
    identify $nodes;
    exit if $options{'probe_level'} == 2;
    
    # Probe Level 2:
    #     netsync executes the discovery and identification stages only.
    #     It probes the database for discovered nodes (logging them appropriately),
    #     and it creates an RFC4180-compliant list of them (default: var/db.csv).
    #     This list may then be used as input to netsync to skip synchronization later.
    
    update $nodes;
}




{ # Read the configuration file.
    say 'configuring (using '.$options{'conf_file'}.')...' unless $options{'quiet'};
    %settings = configure ($options{'conf_file'},{
        'Indent'      => 4,
        'NodeOrder'   => 4, # network < 10000 nodes
        'NodeLog'     => 'var/log/nodes.log',
        'DeviceLog'   => 'var/log/devices.log',
        'BogeyLog'    => 'var/log/bogies.log',
        'UpdateLog'   => 'var/log/updates.log',
        'Probe1Cache' => 'var/dns.txt',
        'Probe2Cache' => 'var/db.csv',
    },1,1,1);
    validate;
}
run;
exit;
