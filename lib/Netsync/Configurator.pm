#!/usr/bin/perl

package Netsync::Configurator;

require Exporter;
@ISA = (Exporter);
@EXPORT = (
            'configure','dump_config','get_config',
            'DB',
            'DNS',
            'SNMP','SNMP_Info','SNMP_get1','SNMP_set',
          );

use autodie;
use strict;

use feature 'say';

use Config::Simple;
use File::Basename;
use Net::DNS;
use Scalar::Util 'blessed';
use SNMP;
use SNMP::Info;


=head1 NAME

Netsync::Configurator - methods for handling configuration files and default settings

=head1 SYNOPSIS

C<use Netsync::Configurator;>

=cut


our $VERSION = '1.0.0';
our %config;
our ($DB,$DNS,$SNMP) = (0,0,0);


=head1 DESCRIPTION

This module is responsible for managing I/O automatically for the programmer.

=head1 METHODS

=head2 configure [($file[,\%defaults[,$DB[,$DNS[,$SNMP]]]])]

returns an POSIX-compliant string representing the current time

=head3 Arguments

=head4 [C<$file>]

a (.ini) configuration file to use
(default: '/etc/'.(basename $0).'/'.(basename $0).'.ini')

=head4 [C<\%defaults>]

a hash that specifies settings' (returned configurations) defaults

=head4 [C<$DB>]

whether to enable database support (default: 0)

=head4 [C<$DNS>]

whether to enable domain support (default: 0)

=head4 [C<$SNMP>]

whether to enable SNMP support (default: 0)

=head3 Example

=over 4

=item C<configure;>

Note: This causes Configurator to attempt reading the configuration file at '/etc/'.(basename $0).'/'.(basename $0).'.ini'
      It will return any configurations in the file found under the (basename $0) group.
      Database, DNS, and SNMP support will be disabled.

=item C<configure ('./special.ini',{
    'general.Log' =E<gt> '/var/log/'.(basename $0).'/'.(basename $0).'.log',
},0,1,1);>

C<say $settings{'general.Log'};>

 > /var/log/example/example.log

=back

=cut

sub configure {
    warn 'too many arguments' if @_ > 5;
    my ($file,$defaults);
    ($file,$defaults,$DB,$DNS,$SNMP) = @_;
    $file     //= '/etc/'.(basename $0).'/'.(basename $0).'.ini'; #'#XXX
    $defaults //= {}; #/#XXX
    $DB       //= 0; #/#XXX
    $DNS      //= 0; #/#XXX
    $SNMP     //= 0; #/#XXX
    
    open (my $ini,'<',$file);
    my $parser = Config::Simple->new($file);
    my $syntax = $parser->guess_syntax($ini);
    unless (defined $syntax and $syntax eq 'ini') {
        say 'The config file "'.$file.'" is malformed.';
        return undef;
    }
    close $ini;
    
    Config::Simple->import_from($file,\%config);
    foreach (sort keys %config) {
        $config{$_} = undef if ref $config{$_} and not defined $config{$_}[0];
    }
    $config{'general.Log'} //= '/var/log/'.(basename $0).'/'.(basename $0).'.log'; #'#XXX
    $config{(basename $0).'.'.$_} //= $defaults->{$_} foreach keys %$defaults; #/#XXX
    
    my $message = ' config is inadequate.';
    if ($DB) {
        $config{'DB.AutoCommit'}         //= 0; #/#XXX
        $config{'DB.PrintError'}         //= 1; #/#XXX
        $config{'DB.PrintWarn'}          //= 0; #/#XXX
        $config{'DB.RaiseError'}         //= 0; #/#XXX
        $config{'DB.ShowErrorStatement'} //= 0; #/#XXX
        $config{'DB.TraceLevel'}         //= 0; #/#XXX
        warn 'DB'.$message and return undef unless defined $config{'DB.Server'}   and
                                                   defined $config{'DB.Port'}     and
                                                   defined $config{'DB.DBMS'}     and
                                                   defined $config{'DB.Username'} and
                                                   defined $config{'DB.Password'} and
                                                   defined $config{'DB.Database'};
    }
    if ($DNS) {
        $config{'DNS.HostPrefix'}        //= ''; #/#XXX
        $config{'DNS.RecordType'}        //= 'A|AAAA'; #/#XXX
        $config{'DNS.debug'}             //= 0; #/#XXX
        $config{'DNS.defnames'}          //= 1; #/#XXX
        $config{'DNS.dnsrch'}            //= 1; #/#XXX
        $config{'DNS.dnssec'}            //= 0; #/#XXX
        $config{'DNS.igntc'}             //= 0; #/#XXX
        $config{'DNS.persistent_tcp'}    //= 0; #/#XXX
        $config{'DNS.persistent_udp'}    //= 0; #/#XXX
        $config{'DNS.port'}              //= 53; #/#XXX
        $config{'DNS.recurse'}           //= 1; #/#XXX
        $config{'DNS.retrans'}           //= 5; #/#XXX
        $config{'DNS.retry'}             //= 4; #/#XXX
        $config{'DNS.srcaddr'}           //= '0.0.0.0'; #/#XXX
        $config{'DNS.srcport'}           //= 0; #/#XXX
        $config{'DNS.tcp_timeout'}       //= 120; #/#XXX
        $config{'DNS.usevc'}             //= 0; #/#XXX
        warn 'DNS'.$message if not defined $config{'DNS.domain'};
    }
    if ($SNMP) {
        $config{'SNMP.AuthProto'}        //= 'MD5'; #/#XXX
        $config{'SNMP.Community'}        //= 'public'; #/#XXX
        $config{'SNMP.PrivProto'}        //= 'DES'; #/#XXX
        $config{'SNMP.RemotePort'}       //= 161; #/#XXX
        $config{'SNMP.Retries'}          //= 5; #/#XXX
        $config{'SNMP.RetryNoSuch'}      //= 0; #/#XXX
        $config{'SNMP.SecLevel'}         //= 'noAuthNoPriv'; #/#XXX
        $config{'SNMP.SecName'}          //= 'initial'; #/#XXX
        $config{'SNMP.Timeout'}          //= 1000000; #/#XXX
        $config{'SNMP.Version'}          //= 3; #/#XXX
        $config{'SNMP.ContextEngineId'}  //= $config{'SNMP.SecEngineId'}; #/#XXX
        warn 'SNMP'.$message and return undef unless ($config{'SNMP.Version'} < 3) or
                                                     ($config{'SNMP.SecLevel'} eq 'noAuthNoPriv') or
                                                     ($config{'SNMP.SecLevel'} eq 'authNoPriv' and defined $config{'SNMP.AuthPass'}) or
                                                     (defined $config{'SNMP.AuthPass'} and defined $config{'SNMP.PrivPass'});
    }
    
    my %settings;
    foreach (keys %config) {
        my $basename = basename $0;
        if (/^$basename\.(?<setting>.*)$/) {
            $settings{$+{'setting'}} = $config{$_};
        }
    }
    return %settings;
}


=head2 dump_config

prints the current configuration (use sparingly)

Note: configure needs to be run first!

=cut

sub dump_config {
    warn 'too many arguments' if @_ > 0;
    
    say $_.' = '.($config{$_} // 'undef') foreach sort keys %config; #/#XXX
}


=head2 get_config @queries

returns any number of requests (in an array with corresponding entries) for configurations

Note: configure needs to be run first!

=head3 Arguments

=head4 C<@queries>

the configurations to retrieve

=head3 Example

=over 4

=item C<say get_config 'DNS.domain';>

 > example.com

=item C<say $_ foreach get_config ('DB.DBMS','DB.Database');>

 > (postgres|mysql|oracle)
 > (database name)

=back

=cut

sub get_config {
    warn 'too few arguments'  if @_ < 1;
    my (@queries) = @_;
    
    return $config{$queries[0]} if @queries == 1;
    my @responses;
    push (@responses,$config{$_}) foreach @queries;
    return @responses;
}


=head2 DB

returns a configured DBI connection to a database

Note: configure needs to be run first!

=cut

sub DB {
    warn 'too many arguments' if @_ > 0;
    return undef unless $DB;
    
    my $data_source  = 'dbi:'.$config{'DB.DBMS'};
       $data_source .= ':host='.$config{'DB.Server'};
       $data_source .= ';database='.$config{'DB.Database'};
       $data_source .= ';port='.$config{'DB.Port'};
    if (defined $config{'DB.DSN'}) {
        if (ref $config{'DB.DSN'}) {
            $data_source .= ';'.$_ foreach @{$config{'DB.DSN'}};
        }
        else {
            $data_source .= ';'.$config{'DB.DSN'};
        }
    }
    return DBI->connect($data_source,$config{'DB.Username'},$config{'DB.Password'},{
        'AutoCommit'         => $config{'DB.AutoCommit'},
        'PrintError'         => $config{'DB.PrintError'},
        'PrintWarn'          => $config{'DB.PrintWarn'},
        'RaiseError'         => $config{'DB.RaiseError'},
        'ShowErrorStatement' => $config{'DB.ShowErrorStatement'},
        'TraceLevel'         => $config{'DB.TraceLevel'},
    });
}


=head2 DNS

returns a configured Net::DNS resolver

Note: configure needs to be run first!

=cut

sub DNS {
    warn 'too few arguments'  if @_ < 0;
    warn 'too many arguments' if @_ > 0;
    return undef unless $DNS;
    
    my $DNS_config = {
        'debug'          => $config{'DNS.debug'},
        'defnames'       => $config{'DNS.defnames'},
        'dnsrch'         => $config{'DNS.dnsrch'},
        'dnssec'         => $config{'DNS.dnssec'},
        'domain'         => $config{'DNS.domain'},
        'igntc'          => $config{'DNS.igntc'},
        'persistent_tcp' => $config{'DNS.persistent_tcp'},
        'persistent_udp' => $config{'DNS.persistent_udp'},
        'port'           => $config{'DNS.port'},
        'recurse'        => $config{'DNS.recurse'},
        'srcaddr'        => $config{'DNS.srcaddr'},
        'srcport'        => $config{'DNS.srcport'},
        'udp_timeout'    => $config{'DNS.udp_timeout'},
        'usevc'          => $config{'DNS.usevc'},
        'tcp_timeout'    => $config{'DNS.tcp_timeout'},
        'retrans'        => $config{'DNS.retrans'},
        'retry'          => $config{'DNS.retry'},
    };
    if (defined $config{'DNS.nameservers'}) {
        $DNS_config->{'nameservers'} = (ref $config{'DNS.nameservers'}) ?
                                            $config{'DNS.nameservers'} :
                                           [$config{'DNS.nameservers'}];
    }
    if (defined $config{'DNS.searchlist'}) {
        $DNS_config->{'searchlist'}  = (ref $config{'DNS.searchlist'}) ?
                                            $config{'DNS.searchlist'} :
                                           [$config{'DNS.searchlist'}];
    }
    return Net::DNS::Resolver->new(%$DNS_config);
}


=head2 SNMP $ip

returns an SNMP::Session object that can be used to communicate with C<$ip>.

Note: configure needs to be run first!

=head3 Arguments

=head4 C<$ip>

an IP address to connect to

=cut

sub SNMP {
    warn 'too few arguments'  if @_ < 1;
    warn 'too many arguments' if @_ > 1;
    return undef unless $SNMP;
    my ($ip) = @_;
    
    return SNMP::Session->new(
        'AuthPass'        => $config{'SNMP.AuthPass'},
        'AuthProto'       => $config{'SNMP.AuthProto'},
        'Community'       => $config{'SNMP.Community'},
        'Context'         => $config{'SNMP.Context'},
        'ContextEngineId' => $config{'SNMP.ContextEngineId'},
        'DestHost'        => $ip,
        'PrivPass'        => $config{'SNMP.PrivPass'},
        'PrivProto'       => $config{'SNMP.PrivProto'},
        'RemotePort'      => $config{'SNMP.RemotePort'},
        'Retries'         => $config{'SNMP.Retries'},
        'RetryNoSuch'     => $config{'SNMP.RetryNoSuch'},
        'SecEngineId'     => $config{'SNMP.SecEngineId'},
        'SecLevel'        => $config{'SNMP.SecLevel'},
        'SecName'         => $config{'SNMP.SecName'},
        'Timeout'         => $config{'SNMP.Timeout'},
        'Version'         => $config{'SNMP.Version'},
    );
}


=head2 SNMP_Info $ip

returns an SNMP::Info object that can be used to communicate with C<$ip>.

Note: configure needs to be run first!

=head3 Arguments

=head4 C<$ip>

an IP address to connect to OR an SNMP::Session

=cut

=head3 Example

The following snippets are equivalent:

=over 4

=item C<SNMP_Info '10.0.0.1';>

=item C<SNMP_Info SNMP '10.0.0.1';>

=back

=cut

sub SNMP_Info {
    warn 'too few arguments'  if @_ < 1;
    warn 'too many arguments' if @_ > 1;
    return undef unless $SNMP;
    my ($ip) = @_;
    
    my $session = SNMP $ip;
    my $info = SNMP::Info->new(
        'AutoSpecify' => 1,
        'Session'     => $session,
    );
    return ($session,$info);
}


=head2 SNMP_get1 (\@oids,$ip)

attempt to retrieve an OID from a provided list, stopping on success

=head3 Arguments

=head4 C<\@oids>

an array of oids to try and retreive

=head4 C<$ip>

an IP address to connect to OR an SNMP::Session

=head3 Example

=over 4

=item C<($ifNames,$ifs) = SNMP_get1 ([
    ['.1.3.6.1.2.1.31.1.1.1.1' =E<gt> 'ifName'],
    ['.1.3.6.1.2.1.2.2.1.2'    =E<gt> 'ifDescr'],
],'10.0.0.1');>

Note: If ifName is unavailable, ifDescr will be tried.

=back

=cut

sub SNMP_get1 {
    warn 'too few arguments'  if @_ < 2;
    warn 'too many arguments' if @_ > 2;
    my ($oids,$ip) = @_;
    
    my $session = $ip;
    unless (blessed $session and $session->isa('SNMP::Session')) {
        return undef if ref $session;
        $session = SNMP $session;
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


=head2 SNMP_set ($oid,$IID,$value,$ip)

attempt to set a new value on a device using SNMP

=head3 Arguments

=head4 C<$oid>

the OID to write C<$value> to

=head4 C<$IID>

the IID to write C<$value> to

=head4 C<$value>

the value to write to C<$oid>.C<$IID>

=head4 C<$ip>

an IP address to connect to OR an SNMP::Session

=cut

sub SNMP_set {
    warn 'too few arguments'  if @_ < 4;
    warn 'too many arguments' if @_ > 4;
    my ($oid,$IID,$value,$ip) = @_;
    
    my $session = $ip;
    unless (blessed $session and $session->isa('SNMP::Session')) {
        return undef if ref $session;
        $session = SNMP $session;
        return undef unless defined $session;
    }
    
    my $query = SNMP::Varbind->new([$oid,$IID,$value]);
    $session->set($query);
    return ($session->{'ErrorNum'}) ? $session->{'ErrorStr'} : 0;
}


=head1 AUTHOR

David Tucker

=head1 LICENSE

This file is part of netsync.
netsync is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.
netsync is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
See the GNU General Public License for more details.
You should have received a copy of the GNU General Public License along with netsync.
If not, see L<http://www.gnu.org/licenses/>.

=cut


1
