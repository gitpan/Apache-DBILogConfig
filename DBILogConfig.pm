package Apache::DBILogConfig;

require 5.004;

use strict;

# MODULES

use mod_perl 1.11_01;
use Apache::Constants qw( :common );
use DBI;
use Date::Format;

$Apache::DBILogConfig::VERSION = "0.01";

# List of allowed formats and their values
my %Formats = 
  ('b' => sub {my $r = shift; return $r->bytes_sent}, # Bytes sent
   'f' => sub {my $r = shift; return $r->filename}, # Filename
   'e' => sub {my $r = shift; return $r->subprocess_env(shift)}, # Any environment variable
   'h' => sub {my $r = shift; return $r->get_remote_host}, # Remote host
   'a' => sub {my $r = shift; return $r->connection->remote_ip}, # Remote IP Address
   'i' => sub {my $r = shift; return $r->header_in(shift)}, # A header in the client request
   'l' => sub {my $r = shift; return $r->get_remote_logname}, # Remote log name (from identd)
   'n' => sub {my $r = shift; return $r->notes(shift)}, # The contents of a note from another module
   'o' => sub {my $r = shift; return $r->header_out(shift)}, # A header from the reply
   'p' => sub {my $r = shift; return $r->get_server_port}, # Server port
   'P' => sub {return $$}, # Apache child PID
   'r' => sub {my $r = shift; return $r->the_request}, # First line of the request
   's' => sub {my $r = shift; return $r->status}, # Status
   't' => sub {my $r = shift; my $format = shift || "%d/%b/%Y:%X %z"; return time2str $format, time}, # Time: CLF or strftime
   'T' => sub {my $r = shift; return (time - $r->request_time)}, # Time take to serve requests
   'u' => sub {my $r = shift; return $r->connection->user}, # Remote user from auth
   'U' => sub {my $r = shift; return $r->uri}, # URL
   'v' => sub {my $r = shift; return $r->server->server_hostname} # Server hostname
  );

# SUBS

sub logger {

  my $r = shift;
  $r = $r->last; # Handle internal redirects
  $r->subprocess_env; # Setup the environment

  # Connect to the database
  my $source = $r->dir_config('DBILogConfig_data_source');
  my $username = $r->dir_config('DBILogConfig_username');
  my $password = $r->dir_config('DBILogConfig_password');
  my $dbh = DBI->connect($source, $username, $password);
  unless ($dbh) { 
    $r->log_error("Apache::DBILogConfig could not connect to $source - $DBI::errstr");
    return DECLINED;
  } # End unless
  $r->warn("DBILogConfig: Connected to $source as $username");

  # Parse the formats ( %[conditions]{param}format=field [...] )
  my @format_list = (); # List of anon hashes {field, format, param, conditions}
  foreach my $format_string (split /\s+/, Apache->request->dir_config('DBILogConfig_log_format')) {
    my ($format) = ($format_string =~ /(\w)=/);
    my ($field) = ($format_string =~ /=([-\w]+)$/);
    my ($param) = ($format_string =~ /\{([^\}]+)\}/);
    my ($op, $conditions_string) = ($format_string =~ /^%(!?)((?:\d{3},*)+)/);
    my @conditions = map q($r->status ==  ) . $_, split /,/, $conditions_string; # Or conditions together
    my $conditions = join(' or ', @conditions); 
    $conditions = qq{!($conditions)} if $op; # Negate if necessary 
    $conditions ||= 1; # If no conditions we want a guranteed true condition
    $r->warn("DBILogConfig: format=$format, field=$field, param=$param, conditions=$conditions");
    push @format_list, {'field' => $field, 'format' => $format, 'param' => $param, 'conditions' => $conditions};
  } # End foreach

  # Create the statement and insert data
  my $table = $r->dir_config('DBILogConfig_table');
  @format_list = grep eval $_->{'conditions'}, @format_list; # Keep only ones whose conditions are true
  my $fields = join ', ', map $_->{'field'}, @format_list; # Create string of fields
  my $values = join ', ', map $dbh->quote($Formats{$_->{'format'}}->($r, $_->{'param'})), @format_list; # Create str of values
  my $statement = qq(INSERT INTO $table ($fields) VALUES ($values));
  $r->warn("DBILogConfig: statement=$statement");
  $dbh->do($statement);
  
  $dbh->disconnect;
  
  return OK; 

} # End logger

sub handler {shift->post_connection(\&logger)}

1;

__END__

=head1 NAME

Apache::DBILogConfig - Logs access information in a DBI database

=head1 SYNOPSIS

 # In httpd.conf
 PerlLogHandler Apache::DBILogConfig
 PerlSetVar DBILogConfig_data_source DBI:Informix:log_data
 PerlSetVar DBILogConfig_username    informix
 PerlSetVar DBILogConfig_password    informix
 PerlSetVar DBILogConfig_table	     mysite_log
 PerlSetVar DBILogConfig_log_format  "%b=bytes_sent %f=filename %h=remote_host %r=request %s=status"

=head1 DESCRIPTION

This module replicates the functionality of the standard Apache module, mod_log_config,
but logs information in a DBI-compliant database instead of a file.

=head1 LIST OF TOKENS

=over 4

=item DBILogConfig_data_source

A DBI data source with a format of "DBI::driver:database"

=item DBILogConfig_username

Username passed to the database driver when connecting

=item DBILogConfig_password

Password passed to the database driver when connecting

=item DBILogConfig_table

Table in the database for logging

=item DBILogConfig_log_format

A string consisting of formats seperated by white space that define the data to be looged (see FORMATS below)

=back

=head1 FORMATS

A format consists of a string with the following syntax: 

B<%[conditions][{parameter}]format=field>

=head2 format

Formats specify the type of data to be logged. The following formats are accepted:

=over

=item b Bytes sent

=item f Filename

=item e Environment variable (specified by parameter)

=item h Remote host

=item a Remote IP Address

=item i Header in the client request (specified by parameter)

=item l Remote log name (from identd)

=item n Contents of a note from another module (specified by parameter)

=item o Header from the reply (specified by parameter)

=item p Server port

=item P Apache child PID

=item r First line of the request

=item s Request status

=item t Time in common log format (default) or strftime() (parameter)

=item T Time taken to serve request

=item u Remote user from auth

=item U URL

=item v Server hostname

=back

=head2 field

A database column to log the data to

=head2 parameter

For formats that take a parameter

Example: %{DOCUMENT_ROOT}e 

=head2 conditions

Conditions are a comma-seperated list of status codes. If the status of the request being logged equals one of 
the status codes in the condition the data specified by the format will be logged. By placing a '!' in front of
the conditions, data will be logged if the request status does not match any of the conditions.

Example: %!200,304,302s=status will log the status of all requests that did not return some sort of normal status

=head1 DEBUGGING

Debugging statements will be written to the error log if LOGLEVEL is set to 'warn' or higher

=head1 PREREQUISITES

=over

=item * mod_perl >= 1.11_01 with PerlLogHandler enabled

=item * DBI

=item * Date::Format

=back

=head1 INSTALLATION

To install this module, move into the directory where this file is
located and type the following:

        perl Makefile.PL
        make
        make test
        make install

This will install the module into the Perl library directory. 

Once installed, you will need to modify your web server's configuration as above.

=head1 AUTHOR

Copyright (C) 1998, Jason Bodnar <jcbodnar@mail.utexas.edu>. All rights reserved.

This module is free software; you may redistribute it and/or
modify it under the same terms as Perl itself.

=head1 SEE ALSO

perl(1), mod_perl(3)

=cut
