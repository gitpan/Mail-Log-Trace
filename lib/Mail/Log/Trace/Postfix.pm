#!/usr/bin/perl

=head1 NAME

Mail::Log::Trace::Postfix - Trace an email through Postfix logs.

=head1 SYNOPSIS

  use Mail::Log::Trace::Postfix;
  
  my $tracer = Mail::Log::Trace::Postfix->new({log_file => 'path/to/log'});
  $tracer->set_message_id('message_id');
  $tracer->find_message();
  my $from_address = $tracer->get_from_address();
  
  etc.

=head1 DESCRIPTION

A subclass for L<Mail::Log::Trace> that handles Postfix logs.  See the
documentation for the root class for more.  This doc will just deal with the
additions to the base class.

=head1 USAGE

An object-oriented module: See the base class for most of the meathods.

Additions are:

=head2 SETTERS

=cut

package Mail::Log::Trace::Postfix;
{
use strict;
use warnings;
use Scalar::Util qw(refaddr);
#use Mail::Log::Parse::Postfix;
use Mail::Log::Exceptions;
use base qw(Mail::Log::Trace);
use constant EMPTY_STRING => qw{};

BEGIN {
    use Exporter ();
    use vars qw($VERSION @EXPORT @EXPORT_OK %EXPORT_TAGS);
    $VERSION     = '1.0';
}

#
# Define class variables.  Note that they are hashes...
#

my %message_info;
my %log_info;

#
# DESTROY class variables.
#

### IF NOT DONE THERE IS A MEMORY LEAK.  ###

sub DESTROY {
	my ($self) = @_;
	
	delete $message_info{refaddr $self};
	delete $log_info{refaddr $self};
	
	$self->SUPER::DESTROY();
	
	return;
}

=head3 set_connection_id

Sets the connection id of the message we are looking for.

=cut

sub set_connection_id {
	my ($self, $new_id) = @_;
	$message_info{refaddr $self}{'connection_id'} = $new_id;
	return;
}

=head3 set_process_id

Sets the process id of the message we are looking for.  (Note that pids are
often reused, and Postfix will use several processes for a specific message.)

=cut

sub set_process_id {
	my ($self, $new_id) = @_;
	$message_info{refaddr $self}{'process_id'} = $new_id;
	return;
}

=head3 set_status

Sets the status id of the message we are looking for.

Currently this is the B<full> status, not just the numeric code.

=cut

sub set_status {
	my ($self, $new_id) = @_;
	$message_info{refaddr $self}{'status'} = $new_id;
	return;
}

=head3 set_year

Sets the year the logfile was written in, since Postfix doesn't log that.

Assumes the current year if not set.  (See L<Mail::Log::Parse::Postfix>.)

=cut

sub set_year {
	my ($self, $year) = @_;
	$log_info{refaddr $self}{year} = $year;
	
	# If we've already opened the log file, set the year in the log file.
	my $maillog = $self->_get_log_parser();
	if (defined($maillog)) {
		$maillog->set_year($year);
	}
	return;
}

=head2 GETTERS

=head3 get_connection_id

Returns the connection id of the message we are looking for/have found.

=cut

#
# Getters.
#
sub get_connection_id {
	my ($self) = @_;
	return $message_info{refaddr $self}{'connection_id'};
}

=head3 get_process_id

Returns the process id of the message we are looking for/have found.

This will be the process id of the first part of the message found, which may
or may not be the first entry of the message in the log.

=cut

sub get_process_id {
	my ($self) = @_;
	return $message_info{refaddr $self}{'process_id'};
}

=head3 get_status

Returns the status of the message we are looking for/have found.

Currently this is the B<full> status, not just the numeric code.

=cut

sub get_status {
	my ($self, $new_id) = @_;
	return $message_info{refaddr $self}{'status'};
}

#
# Overridden methods.
#

sub clear_message_info {
	my ($self) = @_;

	# Call the super, to clear out it's info:
	$self->SUPER::clear_message_info();

	$self->set_connection_id(undef);
	$self->set_process_id(undef);
	$self->set_status(undef);

	return;
}

sub find_message {
	my ($self, $argref) = @_;

	# Parse the arguments, and get all the message info.
	my $msg_info = $self->_parse_args($argref, 1);	# The '1' means throw an error if we don't have any info.

	# Open the log file.  (Unless we've already opened it.)
	my $maillog = $self->_get_log_parser();
	unless ( defined($maillog) ) {
		my $parser_class = $self->_get_parser_class();
		$parser_class = defined($parser_class) ? $parser_class : 'Mail::Log::Parse::Postfix';
		eval "require $parser_class;";
		
		if ( defined($log_info{refaddr $self}{year}) ) {
			$maillog = eval "$parser_class->new({log_file => \$self->get_log(), year => \$log_info{refaddr \$self}{year}});";
		}
		else {
			$maillog = eval "$parser_class->new({log_file => \$self->get_log(),});";
		}
		$self->_set_log_parser($maillog);
	}

	# Normally we start where we left off, but we can start at the beginning.
	if ( $argref->{from_start} ) {
		$maillog->go_to_beginning();
	}

	# Look through the logfile one line at a time, until we've found it.
	my $found_message = 0;
	while ( (my $line_data = $maillog->next()) and !$found_message) {
		#Check to see if this line matches.
		if ( _line_matches($line_data, $msg_info) ) {
			# Save anything we've matched that is new info.
			$self->_read_data_from_line($line_data);

			# Also save the raw info, in case it is wanted.
			$self->_set_message_raw_info($line_data);

			# Ok, we're done.
			$found_message = 1;
		}
	}

	# Return whether we found anything.
	return $found_message;
}

sub find_message_info {
	my ($self, $argref) = @_;

	# If we can't find it, we can't find info on it.
	return undef unless $self->find_message($argref);

	# Get all the message info.
	my $msg_info = $self->_parse_args($argref, 1);
	my $maillog = $self->_get_log_parser();

	# So we can save something in it later.
	my $begin_log_line;

	# Read backwards until we find the start of the connection
	my $start_found = 0;
	while ( !$start_found and (my $line_data = $maillog->previous()) ) {
		# Reset process ID's if we find earlier ones.  (We trust the connection ID.)
		if ( defined($line_data->{id}) and $line_data->{id} eq $msg_info->{connection_id} ) {
			$msg_info->{process_id} = $line_data->{pid};
		}

		# The connection doesn't list the connection ID, but it's process
		# ID will match a later line that does...
		if ( ($line_data->{pid} eq $msg_info->{process_id}) and $line_data->{connect} ) {
			$start_found = 1;

			# Set the info we've just found.
			$self->_set_connect_time($line_data->{timestamp});
			
			# Add in new info to the 'raw info'.
			# We'll overwrite what is already there.
			my $temp = $self->get_all_info();
			foreach my $key ( keys %{$temp} ) {
				$line_data->{$key} = $temp->{$key};
			}
			$self->_set_message_raw_info($line_data);

			# Save where we are: We'll go back here later.
			$begin_log_line = $maillog->get_line_number();
		}
	}

	# Read through until we get all the info.
	my $end_found = 0;
	while ( !$end_found and (my $line_data = $maillog->next()) ) {
		#Check to see if this line matches.
		if ( defined($line_data->{id}) and $line_data->{id} eq $msg_info->{connection_id} ) {
			# Save anything we've matched that is new info.
			$self->_read_data_from_line($line_data);

			# Add in new 'raw_info'.
			# Now we need to _merge_ what is already there...
			my $temp = $self->get_all_info();
			my %temp_hash;
			if (defined($line_data->{to}[0])) {
				foreach my $element ( @{$line_data->{to}}, @{$temp->{to}}) {
					$temp_hash{$element} = 1;
				}
				$temp->{to} = [(keys %temp_hash)];
			}
			# The rest doesn't need to be merged; it can be overwritten.
			foreach my $key ( keys %{$line_data} ) {
				if ( defined($line_data->{$key}) and $key ne 'to') {
					$temp->{$key} = $line_data->{$key};
				}
			}
			$self->_set_message_raw_info($temp);

			# Check to see if we're done.
			if ( $line_data->{text} eq 'removed' ) {
				$end_found = 1;
			}
		}

		# Check for disconnect.
		if ( ($line_data->{pid} eq $msg_info->{process_id}) and $line_data->{disconnect} ) {
			$self->_set_disconnect_time($line_data->{timestamp});
		}
	}

	# We're going to go back to where we found the beginning of the connection:
	# It's polite and useful.
	$maillog->go_to_line_number($begin_log_line);

	# Check to see if we found it, and throw an error if we didn't.
	if ( !$start_found ) {
		Mail::Log::Exceptions::Message::IncompleteLog->throw('Connection start predates logfile.');
	}

	# Check to see if we found it, and throw an error if we didn't.
	if ( !$end_found ) {
		Mail::Log::Exceptions::Message::IncompleteLog->throw('Logfile ends before disconnection.');
	}

	return 1;
}

####
#	Private Functions.
####

#
#	parse_agrs: Parses an argument hashref.  Object method.
#
# Takes the hashref that is passed to a meathod, and parses it for possible entries.
# Configures the current object with the arguments, and also passes back a hashref with them inside.
# Optionally, it will throw an exception if there are no arguments passed and the current object is blank.
#
# Arguments: Positional, the hashref to parse, and a boolean of whether to throw an error.
#
# Return value: A hashref with keys for all possible arguements.
#
sub _parse_args {
	my ($self, $argref, $throw_error) = @_;

	my $args;
	eval { $args = $self->SUPER::_parse_args($argref, $throw_error); };

	my $exception = Mail::Log::Exceptions->caught();

	# Get Postfix-specific data.
	$self->set_connection_id($argref->{'connection_id'})	if defined $argref->{'connection_id'};
	$self->set_status($argref->{'status'})					if defined $argref->{'status'};
	$self->set_process_id($argref->{'process_id'})			if defined $argref->{'process_id'};
	$self->set_year($argref->{year})						if defined $argref->{year};

	# Speed things up a bit, and make it easier to read.
	$args->{connection_id}	= $self->get_connection_id();
	$args->{status}			= $self->get_status();
	$args->{process_id}		= $self->get_process_id();

	if ( $throw_error and defined($exception) ) {
		# If none are defined...  (This is actually slightly redundant, but fast.)
		if ( !(grep { defined($args->{$_}) } keys %{$args}) ) {
			$exception->rethrow();
		}
	}

	return $args;
}

#
#	line_matches: Finds whether a line matches the given info.  Function.
#
# Takes a hashref to match against (as returned from Mail::Log::Parse::Postfix)
# and a hashref of data (internal format, see code.)  Checks to see if the
# two hashes match on all that exists in both.  (But _only_ in both: Either can
# have data that the other doesn't, as long as the other has 'undef' for
# that key.)
#
# Arguments: Positional, the hashref from the parser, and the internal hashref.
#
# Return Value: True if they match, False if they do not.
#
sub _line_matches ($$) {
	my ( $line_data, $msg_info) = @_;

	my %line_data_map = (	from_address	=> 'from'
							,message_id		=> 'msgid'
							,relay			=> 'relay'
							,connection_id	=> 'id'
							,status			=> 'status'
						);

	no warnings qw(uninitialized);
	my @defined_data =	grep { ($_ ne 'to_address') and ($_ ne 'from_start') and defined($msg_info->{$_}) } 
							keys %{$msg_info};

	my $matched_data =	grep { ($msg_info->{$_} eq ${$line_data}{$line_data_map{$_}})
							} @defined_data;

	my $unmatched_data = grep { !defined($line_data->{$line_data_map{$_}})
								or ($msg_info->{$_} ne $line_data->{$line_data_map{$_}})
								} @defined_data;

	# Check to addresses
	my $to_count =	grep { my $tmp = $_;
								grep { $_ eq $tmp } @{$line_data->{to}};
							} @{$msg_info->{to_address}};
	if ( $to_count ) {
		$matched_data = $matched_data + $to_count;
	}
	else {
		if ( defined( ${$msg_info->{to_address}}[0]) ) {
			$unmatched_data++;
		}
	}

	return ( ($matched_data > 0) and ($unmatched_data == 0) );
}

#
#	read_data_from_line: Reads data from a parsed line.  Function.
#
# Takes a hashref of data from a Mail:::Log::Parse::Postfix, and sets the values
# in self for all the data we capture, skiping data we already have.
#
# Arguments: Postional, the hashref from the parser.
#
# Return Value: None.
#

sub _read_data_from_line {
	my ($self, $line_data) = @_;
	# Set any info we've found.
	$self->add_to_address($_) foreach (@{$line_data->{to}});
	$self->set_from_address($line_data->{from}) unless defined($self->get_from_address());
	$self->set_message_id($line_data->{msgid}) unless defined($self->get_message_id());
	$self->set_relay_host($line_data->{relay}) unless defined($self->get_relay_host());
	$self->set_status($line_data->{status}) unless defined($self->get_status());
	$self->set_connection_id($line_data->{id}) unless defined($self->get_connection_id());
	$self->_set_delay($line_data->{delay}) if defined($line_data->{delay});

	# Set times, if applicable.
	$self->set_recieved_time($line_data->{timestamp}) if defined($line_data->{msgid});
	$self->set_sent_time($line_data->{timestamp}) if defined($line_data->{to}->[0]);

	return;
}

=head1 BUGS

Tracing a message works, but is slow.  The statuses should probably be smart
about what they take/return, so we can say 'find all rejected messages' or
something of the sort...

=head1 REQUIRES

L<Scalar::Util>, L<Mail::Log::Exceptions>, L<Mail::Log::Trace>

Something that can pretend it is L<Mail::Log::Parse::Postfix>.  (The actual class
B<not> required, but it is the default.  Another parser class can be set at
runtime.  However, it is assumed to behave exactly like Mail::Log::Parse::Postfix.)

=head1 HISTORY

1.0 Nov 28, 2008.
    - original version.

=head1 AUTHOR

    Daniel T. Staal
    CPAN ID: DSTAAL
    dstaal@usa.net

=head1 COPYRIGHT

This program is free software; you can redistribute
it and/or modify it under the same terms as Perl itself.

This licence will expire in 30 years, or five years after the author's death,
whichever occurs last.

=head1 SEE ALSO

L<Mail::Log::Trace>

=cut

#################### main pod documentation end ###################

}
1;
# The preceding line will help the module return a true value

