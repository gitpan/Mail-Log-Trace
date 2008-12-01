#!/usr/bin/perl


package Mail::Log::Trace;
{
=head1 NAME

Mail::Log::Trace - Trace an email through the mailsystem logs.

=head1 SYNOPSIS

  use Mail::Log::Trace;
  
  my $tracer = Mail::Log::Trace::SUBCLASS->new({log_file => 'path/to/log'});
  $tracer->set_message_id('message_id');
  $tracer->find_message();
  my $from_address = $tracer->get_from_address();
  
  etc.

=head1 DESCRIPTION

This is the root-level class for a mail tracer: It allows you to search for
and find messages in maillogs.  Accessors are provided for info common to
most maillogs: Specific subclasses may have further accessors depending on their
situation.

Probably the two methods most commonly used (and sort of the point of this
module) are C<find_message> and C<find_message_info>.  Both are simply stubs
for subclasses to implement:  The first is defined to find the first (or first
from current location...) mention of the specified message in the log.
Depending on the log format that may or may not be the only mention, and there
may be information missing/incomplete at that point.

C<find_message_info> should find I<all> information about a specific message
in the log.  (Well, all information about a specific instance of the message:
If there are multiple messages that would match the info provided it must
find info on the first found.)  That may mean searching through the log for
other information.

If you just need to find if the message exists, use C<find_message>: it will
be faster (or at the least, the same speed.  It should never be slower.)

=head1 USAGE

This is a an object-orientend module, with specific methods documented below.

The string coersion is overloaded to return the class name, and the file
we are working with.  Boolean currently checks to see if we were able to
open the file.  (Which is kinda silly, as we'd through an error if we couldn't.)

All times are expected to be in Unix epoc-time format.

=cut

use strict;
use warnings;
use Scalar::Util qw(refaddr blessed reftype);
use Mail::Log::Exceptions;
use base qw(Exporter);

BEGIN {
    use Exporter ();
    use vars qw($VERSION @EXPORT @EXPORT_OK %EXPORT_TAGS);
    $VERSION     = '1.0001';
    #Give a hoot don't pollute, do not export more than needed by default
    @EXPORT      = qw();
    @EXPORT_OK   = qw();
    %EXPORT_TAGS = ();
}

#
# Define class variables.  Note that they are hashes...
#

my %message_info;
my %log_info;
my %message_raw_info;

#
# DESTROY class variables.
#
### IF NOT DONE THERE IS A MEMORY LEAK.  ###

sub DESTROY {
	my ($self) = @_;
	
	delete $message_info{refaddr $self};
	delete $log_info{refaddr $self};
	delete $message_raw_info{refaddr $self};
	
	return;
}

#
# Set the coercions to something useful.
#

use overload (
	# Strings overload to the path and line number.
	qw{""} => sub { my ($self) = @_;
					return  blessed($self)
							.' File: '
							.$log_info{refaddr $self}{'filename'};
					},
	
	# Boolean overloads to if we are usable.  (Have a filehandle.)
	qw{bool} => sub { my ($self) = @_;
						return defined($log_info{refaddr $self}{'log_parser'});
					},
	
	# Numeric context just doesn't mean anything.  Throw an error.
	q{0+} => sub { Mail::Log::Exceptions->throw(q{Can't get a numeric value of a Mail::Log::Trace.} );
				},
	
	# Perl standard for everything else.
	fallback => 1,
			);


=head2 new (constructor)

The base constructor for the Mail::Log::Trace classes.  It takes inital values
for the following in a hash: C<from_address>, C<to_address>, C<message_id>,
C<log_file>.  The only required value is the path to the logfile.

    use Mail::Log::Trace;
    my $object = Mail::Log::Trace->new({  from_address => 'from@example.com',
                                          to_address   => 'to@example.com',
                                          message_id   => 'messg.id.string',
                                          log_file     => 'path/to/log',
                                        });

=cut

sub new
{
    my ($class, $parameters_ref) = @_;

    my $self = bless \do{my $anon}, $class;

	# Set up any/all passed parameters.
	# (Only does message info.)
	$self->_parse_args($parameters_ref, 0);

	# Log info.
	$self->set_log($parameters_ref->{'log_file'});  # Better to keep validation together.

    return $self;
}

#
# Setters.
#

=head2 SETTERS

=head3 set_from_address

Sets the from address of the message we are looking for.

=cut

sub set_from_address {
	my ($self, $new_address) = @_;
	$message_info{refaddr $self}{'from_address'} = $new_address;
	return;
}

=head3 set_message_id

Sets the message_id of the message we are looking for.
(Check with the specific parser class for what that means in a particular
log format.)

=cut

sub set_message_id {
	my ($self, $new_id) = @_;
	$message_info{refaddr $self}{'message_id'} = $new_id;
	return;
}

=head3 set_recieved_time

Sets the recieved time of the message we are looking for.
(The time this machine got the message.)

=cut

sub set_recieved_time {
	my ($self, $new_id) = @_;
	$message_info{refaddr $self}{'recieved_time'} = $new_id;
	return;
}

=head3 set_sent_time

Sets the sent time of the message we are looking for.
(The time this machine sent the message.)

=cut

sub set_sent_time {
	my ($self, $new_id) = @_;
	$message_info{refaddr $self}{'sent_time'} = $new_id;
	return;
}

=head3 set_relay_host

Sets the relay host of the message we are looking for.  Commonly either
the relay we recieved it from, or the relay we sent it to.  (Depending
on the logfile.)

=cut

sub set_relay_host {
	my ($self, $new_id) = @_;
	$message_info{refaddr $self}{'relay'} = $new_id;
	return;
}

=head3 set_subject

Sets the subject of the message we are looking for.

=cut

sub set_subject {
	my ($self, $new_id) = @_;
	$message_info{refaddr $self}{subject} = $new_id;
	return;
}

=head3 set_parser_class

Sets the parser class to use when searching the log file.  A subclass will
have a 'default' parser that it will normally use: This is to allow easy
site-specific logfile formats based on more common formats.  To use you
would subclass the default parser for the log file format of the base program
to handle the site's specific changes.

Takes the name of a class as a string, and will throw an exception 
(C<Mail::Log::Exceptions::InvalidParameter>) if that class name doesn't start
with Mail::Log::Parse.

=cut

sub set_parser_class {
	my ($self, $new_id) = @_;
	if ( $new_id =~ /Mail::Log::Parse::/ ) {
		$log_info{refaddr $self}{parser_class} = $new_id;
	}
	else {
		Mail::Log::Exceptions::InvalidParameter->throw('Parser class needs to be a Mail::Log::Parse:: subclass.');
	}
	return;
}

=head3 set_log

Sets the log file we are searching throuh.  Takes a full or relative path.
If it doesn't exist, or can't be read by the current user, it will throw an
exception. (C<Mail::Log::Exceptions::LogFile>)  Note that it does I<not>
try to open it immedeately.  That will be done at first attempt to read from
the logfile.

=cut

sub set_log {
	my ($self, $new_name) = @_;

	if ( ! defined($new_name) ) {
		Mail::Log::Exceptions::InvalidParameter->throw('No log file specified in call to '.blessed($self).'->new().');
	}

	# Check to make sure the file exists,
	# and then that we can read it, before accpeting the filename.
	if ( -e $new_name ) {
		if ( -r $new_name ) {
			$log_info{refaddr $self}{'filename'} = $new_name;
		}
		else {
			Mail::Log::Exceptions::LogFile->throw("Log file $new_name is not readable.");
		}
	}
	else {
		Mail::Log::Exceptions::LogFile->throw("Log file $new_name does not exist.");
	}

	# Reset the parser.
	$self->_set_log_parser(undef);

	return;
}

=head3 set_to_address

Sets the to address of the message we are looking for.  Multiple addresses can
be specified, they will all be added, with duplicates skipped.  This method
completely clears the array: there will be no addresses in the list except
those given to it.  Duplicates will be consolidated: Only one of any particular
address will be in the final array.

As a special case, passing C<undef> to this will set the array to undef.

=cut

# 'to' is a little special: it can have multiple values.
sub set_to_address {
	my ($self, $new_address) = @_;
	if (defined($new_address) ) {
		@{$message_info{refaddr $self}{'to_address'}} = ();
		$self->add_to_address($new_address);
	}
	else {
		$message_info{refaddr $self}->{to_address} = undef;
	}
	return;
}

=head3 add_to_address

Adds to the list of to addresses we are looking for.  It does I<not> delete the
array first.

Duplicates will be consolidated, so that the array will only have one of any
given address.  (No matter the order they are given in.)

=cut

sub add_to_address {
	my ($self, $new_address) = @_;
	
	# If we are given a single address, and we haven't seen it before,
	# add it to the array.
	if ( !defined(reftype($new_address)) ) {
		unless ( grep { $_ eq $new_address } @{$message_info{refaddr $self}{'to_address'}} ) {
			push @{$message_info{refaddr $self}{'to_address'}}, ($new_address);
		}
	}
	# If we are given an array of address, merge it with our current array.
	elsif ( reftype($new_address) eq 'ARRAY' ) {
		my %temp_hash;
		foreach my $address (@{$message_info{refaddr $self}{'to_address'}}, @{$new_address}) {
			$temp_hash{$address} = 1;
		}
		@{$message_info{refaddr $self}{'to_address'}} = keys %temp_hash;
	}
	return;
}

=head3 remove_to_address

Removes a single to address from the array.

=cut

sub remove_to_address {
	my ($self, $address) = @_;
	@{$message_info{refaddr $self}{'to_address'}}
		= grep { $_ ne $address } @{$message_info{refaddr $self}{'to_address'}};
	return;
}

#
# Getters.
#

=head2 GETTERS

=head3 get_from_address

Gets the from address.  (Either as set using the setter, or as found in the
log.)

=cut

sub get_from_address {
	my ($self) = @_;
	return $message_info{refaddr $self}{'from_address'};
}

=head3 get_to_address

Gets the to address array.  (Either as set using the setters, or as found in the
log.)

Will return a reference to an array, or 'undef' if the to address has not been
set/found.

=cut

sub get_to_address {
	my ($self) = @_;
	return $message_info{refaddr $self}{'to_address'};
}

=head3 get_message_id

Gets the message_id.  (Either as set using the setter, or as found in the
log.)

=cut

sub get_message_id {
	my ($self) = @_;
	return $message_info{refaddr $self}{'message_id'};
}

=head3 get_subject

Gets the message subject.  (Either as set using the setter, or as found in the
log.)

=cut

sub get_subject {
	my ($self) = @_;
	return $message_info{refaddr $self}{subject};
}

=head3 get_recieved_time

Gets the recieved time.  (Either as set using the setter, or as found in the
log.)

=cut

sub get_recieved_time {
	my ($self) = @_;
	return $message_info{refaddr $self}{'recieved_time'};
}

=head3 get_sent_time

Gets the sent time.  (Either as set using the setter, or as found in the
log.)

=cut

sub get_sent_time {
	my ($self) = @_;
	return $message_info{refaddr $self}{'sent_time'};
}

=head3 get_relay_host

Gets the relay host.  (Either as set using the setter, or as found in the
log.)

=cut

sub get_relay_host {
	my ($self) = @_;
	return $message_info{refaddr $self}{'relay'};
}

=head3 get_log

Returns the path to the logfile we are reading.

=cut

sub get_log {
	my ($self) = @_;
	return  $log_info{refaddr $self}{'filename'};
}

=head3 get_connect_time

Returns the time the remote host connected to this host to send the message.

=cut

sub get_connect_time {
	my ($self) = @_;
	return $log_info{refaddr $self}{'connect_time'};
}

=head3 get_disconnect_time

Returns the time the remote host disconnected from this host after sending
the message.

=cut

sub get_disconnect_time {
	my ($self) = @_;
	return $log_info{refaddr $self}{'disconnect_time'};
}

=head3 get_delay

Returns the total delay in this stage in processing the message.

=cut

sub get_delay {
	my ($self) = @_;
	return $message_info{refaddr $self}{delay};
}

=head3 get_all_info

Returns message info as returned from the parser, for more direct/complete
access.

(It's probably a good idea to avoid using this, but it is useful and arguably
needed under certain circumstances.)

=cut

sub get_all_info {
	my ($self) = @_;
	return $message_raw_info{refaddr $self};
}

#
# To be implemented by the sub-classes.
#

=head2 Utility subroutines

=head3 clear_message_info

Clears I<all> known information on the current message, but not on the log.

Use to start searching for a new message.

=cut

sub clear_message_info {
	my ($self) = @_;
	
	$self->set_from_address(undef);
	$self->set_message_id(undef);
	$self->set_recieved_time(undef);
	$self->set_sent_time(undef);
	$self->set_relay_host(undef);
	$self->set_to_address(undef);
	$self->set_subject(undef);
	$self->_set_connect_time(undef);
	$self->_set_disconnect_time(undef);
	$self->_set_delay(undef);
	$self->_set_message_raw_info(undef);

	return;
}

=head3 find_message

Finds the first/next occurance of a message in the log.  Can be passed any
of the above information in a hash format.

Default is to search I<forward> in the log: If you have already done a search,
this will start searching where the previous search ended.  To start over
at the beginning of the logfile, set C<from_start> as true in the parameter
hash.

This method needs to be overridden by the subclass: by default it will throw
an C<Mail::Log::Exceptions::Unimplemented> error.

=cut

sub find_message {
	Mail::Log::Exceptions::Unimplemented->throw("Method 'find_message' needs to be implemented by subclass.\n");
#	return 0;	# Return false: The message couldn't be found.  This will never be called.
}

=head3 find_message_info

Finds as much information as possible about a specific occurance of a message
in the logfile.  Acts much the same as find_message, other than the fact that
once it finds a message it will do any searching necarry to find all information
on that message connection.

(Also needs to be implemented by subclasses.)

=cut

sub find_message_info {
	Mail::Log::Exceptions::Unimplemented->throw("Method 'find_message_info' needs to be implemented by subclass.\n");
#	return 0;	# Return false: The message couldn't be found.  This will never be called.
}

#
# Private functions/methods.
#

sub _set_connect_time {
	my ($self, $new_time) = @_;
	$log_info{refaddr $self}->{connect_time} = $new_time;
	return;
}

sub _set_disconnect_time {
	my ($self, $new_time) = @_;
	$log_info{refaddr $self}->{disconnect_time} = $new_time;
	return;
}

sub _set_delay {
	my ($self, $new_delay) = @_;
	$message_info{refaddr $self}->{delay} = $new_delay;
	return;
}

sub _set_message_raw_info {
	my ($self, $new_hash) = @_;
	$message_raw_info{refaddr $self} = $new_hash;
	return;
}

sub _set_log_parser {
	my ($self, $log_parser) = @_;
	$log_info{refaddr $self}->{log_parser} = $log_parser;
	return;
}

sub _get_log_parser {
	my ($self) = @_;
	return $log_info{refaddr $self}->{log_parser};
}

sub _get_parser_class {
	my ($self) = @_;
	return $log_info{refaddr $self}->{parser_class};
}

#
# Private to be implemented by the sub-classes...
# (If needed.)
#

sub _parse_args {
	my ($self, $argref, $throw_error) = @_;
	
	# It is possible for them to pass the message info here.
	$self->set_from_address($argref->{'from_address'})		if exists $argref->{'from_address'};
	$self->set_to_address($argref->{'to_address'})			if exists $argref->{'to_address'};
	$self->set_message_id($argref->{'message_id'})			if exists $argref->{'message_id'};
	$self->set_relay_host($argref->{'relay_host'})			if exists $argref->{'relay_host'};
	$self->set_sent_time($argref->{'sent_time'})			if exists $argref->{'sent_time'};
	$self->set_recieved_time($argref->{'recieved_time'})	if exists $argref->{'recieved_time'};
	$self->set_subject($argref->{subject})					if exists $argref->{subject};
	
	# And log info...
	$self->set_parser_class($argref->{parser_class})		if exists $argref->{parser_class};

	if ( exists $argref->{'to_address'} ) {
		no warnings qw(uninitialized);
		if ( reftype($argref->{'to_address'}) eq 'ARRAY' ) {
			$self->set_to_address();
			map { $self->add_to_address($_) } @{$argref->{'to_address'}};
		}
		else {
			$self->set_to_address($argref->{'to_address'});
		}
	}

	# Speed things up a bit, and make it easier to read.
	my %args;
	$args{from_address}	= $self->get_from_address();
	$args{to_address}	= $self->get_to_address();
	$args{message_id}	= $self->get_message_id();
	$args{relay}		= $self->get_relay_host();
	$args{sent_time}	= $self->get_sent_time();
	$args{recieved_time}= $self->get_recieved_time();
	$args{subject}		= $self->get_subject();
	$args{from_start}	= $argref->{from_start} ? 1 : 0;
	
	if ($throw_error) {
		# If none are defined...
		if ( (grep { defined($args{$_}) } keys %args) == 1 ) {
			Mail::Log::Exceptions::Message->throw("Warning: Trying to search for a message with no message-specific data.\n");
		}
	}

	return \%args;
}

=head1 BUGS

None known at the moment...

=head1 REQUIRES

L<Scalar::Util>, L<Mail::Log::Exceptions>.

Some subclass, and probably a L<Mail::Log::Parse> class to be useful.

=head1 HISTORY

1.00.01 Dec 1, 2008 - Requirements fix, no code changes.

1.00.00 Nov 28, 2008
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

=cut

#################### main pod documentation end ###################

}
1;
# The preceding line will help the module return a true value

