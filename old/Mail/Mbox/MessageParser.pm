package Mail::Mbox::MessageParser;

require Exporter;

no strict;

@ISA = qw(Exporter);
@EXPORT = qw();
@EXPORT_OK = qw( $DEBUG SETUP_CACHE CLEAR_CACHE RESET_CLASS_STATE );

use strict;
use vars qw( $VERSION $DEBUG );

$VERSION = '1.01';

# Need this for a lookahead.
my $READ_CHUNK_SIZE = 20000;

$DEBUG = 0;

# The class-wide cache, which will be read and written when necessary. i.e.
# read when an folder reader object is created which uses caching, and
# written when a different cache is specified, or when the program exits, 
my $CACHE = undef;

my $GREP_DATA = {};

my %CACHE_OPTIONS = ();

my $USING_CACHE = 1;

my $UPDATING_CACHE = 0;

my $CACHE_MODIFIED = 0;

my $HAS_GREP = undef;

#-------------------------------------------------------------------------------

# Outputs debug messages if $DEBUG is true. Be sure to return 1 so code like
# 'dprint "blah\n" and exit' works.

sub dprint
{
  return 1 unless $DEBUG;

  my $message = join '',@_;

  foreach my $line (split /\n/, $message)
  {
    warn "DEBUG (" . __PACKAGE__ . "): $line\n";
  }

  return 1;
}

#-------------------------------------------------------------------------------

sub SETUP_CACHE
{
  my $options = shift;

  die __PACKAGE__ . ": You must provide a \"file_name\" parameter to SETUP_CACHE\n"
    unless defined $options->{'file_name'};

  # Load Storable if we need to
  unless (defined $Storable::VERSION)
  {
    if (eval 'require Storable;')
    {
      import Storable;
    }
    else
    {
      die __PACKAGE__ . ": caching is enabled, " .
        "but you do not have Storable. " .
        "Get it from CPAN.\n";
    }
  }

  # See if the client is setting up a different cache
  if (exists $CACHE_OPTIONS{'file_name'} &&
    $options->{'file_name'} ne $CACHE_OPTIONS{'file_name'})
  {
    dprint "New cache file specified--writing old cache if necessary.";
    WRITE_CACHE() if $USING_CACHE && $CACHE_MODIFIED;
    undef $CACHE;
  }

  %CACHE_OPTIONS = %$options;

  _READ_CACHE() if -f $CACHE_OPTIONS{'file_name'};

  $USING_CACHE = 1;
  $CACHE_MODIFIED = 0;
}

#-------------------------------------------------------------------------------

sub CLEAR_CACHE
{
  # See if the client is setting up a different cache
  unlink $CACHE_OPTIONS{'file_name'}
    if defined $CACHE_OPTIONS{'file_name'} && -f $CACHE_OPTIONS{'file_name'};

  $CACHE = undef;
  $USING_CACHE = 1;
  $CACHE_MODIFIED = 0;
  $UPDATING_CACHE = 0;
}

#-------------------------------------------------------------------------------

sub RESET_CLASS_STATE
{
  $READ_CHUNK_SIZE = 20000;
  $GREP_DATA = {};
  $CACHE = undef;
  %CACHE_OPTIONS = ();
  $USING_CACHE = 1;
  $CACHE_MODIFIED = 0;
  $UPDATING_CACHE = 0;
  $HAS_GREP = undef;
}

#-------------------------------------------------------------------------------

sub _READ_CACHE
{
  my $self = shift;

  dprint "Reading cache";

  # Unserialize using Storable
  $CACHE = retrieve($CACHE_OPTIONS{'file_name'});
}

#-------------------------------------------------------------------------------

sub WRITE_CACHE
{
  # In case this is called during cleanup following an error loading
  # Storable
  return unless defined $Storable::VERSION;

  dprint "Writing cache.";

  # Serialize using Storable
  store($CACHE, $CACHE_OPTIONS{'file_name'});
}

#-------------------------------------------------------------------------------

# Write the cache when the program exits
sub END
{
  dprint "Program is exiting."
    if defined(&Mail::Mbox::MessageParser::dprint);

  WRITE_CACHE() if $USING_CACHE && $CACHE_MODIFIED;
}

#-------------------------------------------------------------------------------

# Options: 
# - file_name: the name of the file. This must be set for caching to occur.
# - file_handle: the file handle to read from
# - enable_grep: set to true if you want to use grep
# - cache_options: a reference to a hash containing cache options
sub new
{
  my ($proto, $options) = @_;

  my $class = ref($proto) || $proto;
  my $self  = {};
  bless ($self, $class);

  $self->{'line_number'} = 1;
  $self->{'offset'} = 0;

  $self->{'file_handle'} = undef;
  $self->{'file_handle'} = $options->{'file_handle'}
    if exists $options->{'file_handle'};

  # The buffer information. (Used when caching is not enabled)
  $self->{'read_buffer'} = '';
  $self->{'start'} = 0;
  $self->{'end'} = 0;

  $self->{'end_of_file'} = 0;

  # The line number of the last read email.
  $self->{'email_line_number'} = 0;
  # The offset of the last read email.
  $self->{'email_offset'} = 0;

  # This is the 0-based number of the email. We'll use it as an index into the
  # cache, if the cache is being used.
  $self->{'email_number'} = 0;

  # We need the file name as a key to the cache
  $self->{'file_name'} = $options->{'file_name'};

  $self->_print_debug_information();

  $self->_validate_and_initialize_cache_entry() if $USING_CACHE;

  $self->{"enable_grep"} = 1;
  $self->{"enable_grep"} = $options->{'enable_grep'}
    if defined $options->{'enable_grep'};

  $self->{"enable_cache"} = $USING_CACHE;
  $self->{"enable_cache"} = $options->{'enable_cache'}
    if defined $options->{'enable_cache'};

  $self->_read_prologue();

  return $self;
}

#-------------------------------------------------------------------------------

sub _read_prologue
{
  my $self = shift;

  if ($self->{'enable_cache'} && !$UPDATING_CACHE)
  {
    $self->_cache_read_prologue();
  }
  elsif ($self->{'enable_grep'} && Has_Grep() &&
    defined $self->{'file_name'} && $self->{'file_name'} !~ /\.(gz|Z|bz2|tz)$/)
  {
    $self->_grep_read_prologue();
  }
  else
  {
    $self->_simple_read_prologue();
  }
}

#-------------------------------------------------------------------------------

sub _cache_read_prologue
{
  my $self = shift;

  dprint "Reading mailbox prologue using cache";

  unless (defined $CACHE->{$self->{'file_name'}}{'offsets'}[0])
  {
    $self->{'prologue'} = '';
    return;
  }

  my $prologue_length = $CACHE->{$self->{'file_name'}}{'offsets'}[0];
  my $bytes_read = 0;

  do
  {
    $bytes_read += read($self->{'file_handle'}, $self->{'prologue'},
      $prologue_length-$bytes_read, $bytes_read);
  } while ($bytes_read != $prologue_length);
}

#-------------------------------------------------------------------------------

sub _grep_read_prologue
{
  my $self = shift;

  dprint "Reading mailbox prologue using grep";

  _READ_GREP_DATA($self->{'file_name'})
    unless defined $GREP_DATA->{$self->{'file_name'}};

  my $prologue_length = $GREP_DATA->{$self->{'file_name'}}{'offsets'}[0];
  my $bytes_read = 0;

  do
  {
    $bytes_read += read($self->{'file_handle'}, $self->{'prologue'},
      $prologue_length-$bytes_read, $bytes_read);
  } while ($bytes_read != $prologue_length);
}

#-------------------------------------------------------------------------------

sub _simple_read_prologue
{
  my $self = shift;

  dprint "Reading mailbox prologue without cache or grep";

  my $current_read_chunk_size = $READ_CHUNK_SIZE;

  # Look for the start of the next email
  LOOK_FOR_FIRST_HEADER:
# TODO: Fromline
  if ($self->{'read_buffer'} =~ m/^
    (X-Draft-From:\s.*|X-From-Line:\s.*|
    From\s
      # Skip names, months, days
      (?> [^:]+ ) 
      # Match time
      (?: :\d\d){1,2}
      # Match time zone (EST), hour shift (+0500), and-or year
      (?: \s+ (?: [A-Z]{2,3} | [+-]?\d{4} ) ){1,3}
      # smail compatibility
      (\sremote\sfrom\s.*)?
    )$/xmg)
  {
    my $start_of_email = pos($self->{'read_buffer'}) - length($1);

    if ($start_of_email == 0)
    {
      $self->{'prologue'} = '';
      return;
    }

    $self->{'prologue'} = substr($self->{'read_buffer'}, 0, $start_of_email);

    $self->{'line_number'} += ($self->{'prologue'} =~ tr/\n//);
    $self->{'offset'} = $start_of_email;
    $self->{'end'} = $start_of_email;

    return;
  }

  # Didn't find next email in current buffer. Most likely we need to read some
  # more of the mailbox.

  # Start looking at the end of the buffer, but back up some in case the edge
  # of the newly read buffer contains the start of a new header. I believe the
  # RFC says header lines can be at most 90 characters long.
  my $search_position = length($self->{'read_buffer'}) - 90;
  $search_position = 0 if $search_position < 0;

  local $/ = undef;

  # Can't use sysread because it doesn't work with ungetc
  if ($current_read_chunk_size == 0)
  {
    local $/ = undef;

    if (eof $self->{'file_handle'})
    {
      $self->{'end_of_file'} = 1;

      $self->{'prologue'} = $self->{'read_buffer'};
      return;
    }
    else
    {
      # < $self->{'file_handle'} > doesn't work, so we use readline
      $self->{'read_buffer'} = readline($self->{'file_handle'});
      pos($self->{'read_buffer'}) = $search_position;
      goto LOOK_FOR_FIRST_HEADER;
    }
  }
  else
  {
    if (read($self->{'file_handle'}, $self->{'read_buffer'},
      $current_read_chunk_size, length($self->{'read_buffer'})))
    {
      pos($self->{'read_buffer'}) = $search_position;
      $current_read_chunk_size *= 2;
      goto LOOK_FOR_FIRST_HEADER;
    }
    else
    {
      $self->{'end_of_file'} = 1;

      $self->{'prologue'} = $self->{'read_buffer'};
      return;
    }
  }
}

#-------------------------------------------------------------------------------

sub prologue
{
  my $self = shift;

  return $self->{'prologue'};
}

#-------------------------------------------------------------------------------

sub _print_debug_information
{
  my $self = shift;

  return unless $DEBUG;

  dprint "Version: $VERSION";

  dprint "Email file: $self->{'file_name'}";
  dprint "Valid cache entry exists: " .
    ($#{ $CACHE->{$self->{'file_name'}}{'lengths'} } != -1 ? "Yes" : "No");
}

#-------------------------------------------------------------------------------

sub _validate_and_initialize_cache_entry
{
  my $self = shift;

  $CACHE_MODIFIED = 0;

  if (!defined $self->{'file_name'})
  {
    warn __PACKAGE__ . ": no file name, so caching is disabled.\n";

    $self->{'enable_cache'} = 0;
    $UPDATING_CACHE = 0;
  }
  else
  {
    my @stat = stat $self->{'file_name'};

    # The file should always exist at this point
    die __PACKAGE__ . ": The file $self->{'file_name'} does not exist!"
      unless scalar(@stat);

    my $size = $stat[7];
    my $time_stamp = $stat[9];

    if (exists $CACHE->{$self->{'file_name'}})
    {
      if ($CACHE->{$self->{'file_name'}}{'size'} != $size ||
        $CACHE->{$self->{'file_name'}}{'time_stamp'} != $time_stamp)
      {
        dprint "Size or time stamp has changed for file " .
          $self->{'file_name'} . ". Invalidating cache entry";

        delete $CACHE->{$self->{'file_name'}};
      }
    }

    if (exists $CACHE->{$self->{'file_name'}})
    {
      $UPDATING_CACHE = 0;
    }
    else
    {
      $CACHE->{$self->{'file_name'}}{'size'} = $size;
      $CACHE->{$self->{'file_name'}}{'time_stamp'} = $time_stamp;
      $CACHE->{$self->{'file_name'}}{'lengths'} = [];
      $UPDATING_CACHE = 1;
    }
  }
}

#-------------------------------------------------------------------------------

# Returns true if the file handle has been fully read
sub end_of_file
{
  my $self = shift;

  return $self->{'end_of_file'};
}

#-------------------------------------------------------------------------------

# The line number of the last email read
sub line_number
{
  my $self = shift;

  return $self->{'email_line_number'};
}

#-------------------------------------------------------------------------------

# The offset of the last email read
sub offset
{
  my $self = shift;

  return $self->{'email_offset'};
}

#-------------------------------------------------------------------------------

# Reads an email from the file and returns it.
# Preconditions:
# - file handle is set and open
# - not end of file
sub _cache_read_next_email
{
  my $self = shift;

  dprint "Using cache" if $DEBUG;

  $self->{'email_line_number'} = $self->{'line_number'};
  $self->{'email_offset'} = $self->{'offset'};

  my $email_length = 
    $CACHE->{$self->{'file_name'}}{'lengths'}[$self->{'email_number'}];

  while (read($self->{'file_handle'}, $self->{'read_buffer'}, $email_length))
  {
    last if $email_length <= length($self->{'read_buffer'});
  }

  $self->{'start'} = 0;
  $self->{'end'} = $email_length;

  if (eof $self->{'file_handle'} &&
    $self->{'end'} == length($self->{'read_buffer'}))
  {
    $self->{'end_of_file'} = 1;
  }

  $self->{'line_number'} +=
    $CACHE->{$self->{'file_name'}}{'line_numbers'}[$self->{'email_number'}];

  $self->{'offset'} +=
    $CACHE->{$self->{'file_name'}}{'offsets'}[$self->{'email_number'}];

  $self->{'email_number'}++;

  return \$self->{'read_buffer'};
}

#-------------------------------------------------------------------------------

# Reads an email from the file and returns it.
# Preconditions:
# - file handle is set and open
# - not end of file
sub _simple_read_next_email
{
  my $self = shift;

  dprint "Not using cache or grep data" if $DEBUG;

  $self->{'email_line_number'} = $self->{'line_number'};
  $self->{'email_offset'} = $self->{'offset'};

  $self->{'start'} = $self->{'end'};

  my $current_read_chunk_size = $READ_CHUNK_SIZE;

  # Look for the start of the next email
  LOOK_FOR_NEXT_HEADER:
  while ($self->{'read_buffer'} =~ m/^
    (X-Draft-From:\s.*|X-From-Line:\s.*|
    From\s
      # Skip names, months, days
      (?> [^:]+ ) 
      # Match time
      (?: :\d\d){1,2}
      # Match time zone (EST), hour shift (+0500), and-or year
      (?: \s+ (?: [A-Z]{2,3} | [+-]?\d{4} ) ){1,3}
      # smail compatibility
      (\sremote\sfrom\s.*)?
    )$/xmg)
  {
    $self->{'end'} = pos($self->{'read_buffer'}) - length($1);

    # Don't stop on email header for the first email in the buffer
    next unless $self->{'end'};

    # Keep looking if the header we found is part of a "Begin Included
    # Message".
    my $end_of_string = substr($self->{'read_buffer'}, $self->{'end'}-200, 200);
    next if $end_of_string =~
        /\n-----(?: Begin Included Message |Original Message)-----\n[^\n]*\n*$/i;

    # Found the next email!
    my $email =
      substr($self->{'read_buffer'}, $self->{'start'}, $self->{'end'}-$self->{'start'});
    $self->{'line_number'} += ($email =~ tr/\n//);
    $self->{'offset'} += length $email;

    if ($UPDATING_CACHE)
    {
      dprint("Storing data into cache, length " . length($email)) if $DEBUG;

      $CACHE->{$self->{'file_name'}}{'lengths'}[$self->{'email_number'}] =
        length($email);

      $CACHE->{$self->{'file_name'}}{'line_numbers'}[$self->{'email_number'}] =
        $self->{'email_line_number'};

      $CACHE->{$self->{'file_name'}}{'offsets'}[$self->{'email_number'}] =
        $self->{'email_offset'};

      $CACHE_MODIFIED = 1;

      $self->{'email_number'}++;
    }
    return \$email;
  }

  # Didn't find next email in current buffer. Most likely we need to read some
  # more of the mailbox. Shift the current email to the front of the buffer
  # unless we've already done so.
  substr($self->{'read_buffer'},0,$self->{'start'}) = '';
  $self->{'start'} = 0;

  # Start looking at the end of the buffer, but back up some in case the edge
  # of the newly read buffer contains the start of a new header. I believe the
  # RFC says header lines can be at most 90 characters long.
  my $search_position = length($self->{'read_buffer'}) - 90;
  $search_position = 0 if $search_position < 0;

  # Can't use sysread because it doesn't work with ungetc
  if ($current_read_chunk_size == 0)
  {
    local $/ = undef;

    if (eof $self->{'file_handle'})
    {
      $self->{'end_of_file'} = 1;

      if ($UPDATING_CACHE)
      {
        dprint("Storing data into cache, length " .
          length($self->{'read_buffer'})) if $DEBUG;

        $CACHE->{$self->{'file_name'}}{'lengths'}[$self->{'email_number'}] =
          length($self->{'read_buffer'});

        $CACHE->{$self->{'file_name'}}{'line_numbers'}[$self->{'email_number'}] =
          $self->{'email_line_number'};

        $CACHE->{$self->{'file_name'}}{'offsets'}[$self->{'email_number'}] =
          $self->{'email_offset'};

        $CACHE_MODIFIED = 1;

        $self->{'email_number'}++;
      }

      return \$self->{'read_buffer'};
    }
    else
    {
      # < $self->{'file_handle'} > doesn't work, so we use readline
      $self->{'read_buffer'} = readline($self->{'file_handle'});
      pos($self->{'read_buffer'}) = $search_position;
      goto LOOK_FOR_NEXT_HEADER;
    }
  }
  else
  {
    if (read($self->{'file_handle'}, $self->{'read_buffer'},
      $current_read_chunk_size, length($self->{'read_buffer'})))
    {
      pos($self->{'read_buffer'}) = $search_position;
      $current_read_chunk_size *= 2;
      goto LOOK_FOR_NEXT_HEADER;
    }
    else
    {
      $self->{'end_of_file'} = 1;

      if ($UPDATING_CACHE)
      {
        dprint("Storing data into cache, length " .
          length($self->{'read_buffer'})) if $DEBUG;

        $CACHE->{$self->{'file_name'}}{'lengths'}[$self->{'email_number'}] =
          length($self->{'read_buffer'});

        $CACHE->{$self->{'file_name'}}{'line_numbers'}[$self->{'email_number'}] =
          $self->{'email_line_number'};

        $CACHE->{$self->{'file_name'}}{'offsets'}[$self->{'email_number'}] =
          $self->{'email_offset'};

        $CACHE_MODIFIED = 1;

        $self->{'email_number'}++;
      }

      return \$self->{'read_buffer'};
    }
  }
}

#-------------------------------------------------------------------------------

sub _READ_GREP_DATA
{
  my $filename = shift;

  my @lines_and_offsets;

  {
    my @grep_results = `grep --extended-regexp --line-number --byte-offset '^(X-Draft-From: .*|X-From-Line: .*|From [^:]+(:[0-9][0-9]){1,2}( +([A-Z]{2,3}|[+-]?[0-9]{4})){1,3}( remote from .*)?)\$' $filename`;

    foreach my $match_result (@grep_results)
    {
      my ($line_number, $byte_offset) = $match_result =~ /^(\d+):(\d+):/;
      push @lines_and_offsets,
        {'line number' => $line_number,'byte offset' => $byte_offset};
    }
  }

  for(my $match_number = 0; $match_number <= $#lines_and_offsets; $match_number++)
  {
    if ($match_number == $#lines_and_offsets)
    {
      my $filesize = -s $filename;
      $GREP_DATA->{$filename}{'lengths'}[$match_number] =
        $filesize - $lines_and_offsets[$match_number]{'byte offset'};
    }
    else
    {
      $GREP_DATA->{$filename}{'lengths'}[$match_number] =
        $lines_and_offsets[$match_number+1]{'byte offset'} -
        $lines_and_offsets[$match_number]{'byte offset'};
    }

    $GREP_DATA->{$filename}{'line_numbers'}[$match_number] =
      $lines_and_offsets[$match_number]{'line number'};

    $GREP_DATA->{$filename}{'offsets'}[$match_number] =
      $lines_and_offsets[$match_number]{'byte offset'};

    $GREP_DATA->{$filename}{'validated'}[$match_number] = 0;
  }
}

#-------------------------------------------------------------------------------

# Reads an email from the file and returns it.
# Preconditions:
# - file handle is set and open
# - not end of file
sub _grep_read_next_email
{
  my $self = shift;

  dprint "Using grep data" if $DEBUG;

  _READ_GREP_DATA($self->{'file_name'})
    unless defined $GREP_DATA->{$self->{'file_name'}};

  $self->{'email_line_number'} =
    $GREP_DATA->{$self->{'file_name'}}{'line_numbers'}[$self->{'email_number'}];
  $self->{'email_offset'} =
    $GREP_DATA->{$self->{'file_name'}}{'offsets'}[$self->{'email_number'}];

  my $email = '';

  LOOK_FOR_NEXT_EMAIL:
  while ($self->{'email_number'} <=
      $#{$GREP_DATA->{$self->{'file_name'}}{'lengths'}})
  {
    {
      my $bytes_read = 0;
      my $current_length = length($email);
      do
      {
        $bytes_read += read($self->{'file_handle'},$email,
        $GREP_DATA->{$self->{'file_name'}}{'lengths'}[$self->{'email_number'}]-$current_length,
        $current_length);
      } while ($bytes_read != 
        $GREP_DATA->{$self->{'file_name'}}{'lengths'}[$self->{'email_number'}]-$current_length);
    }

    last LOOK_FOR_NEXT_EMAIL
      if $GREP_DATA->{$self->{'file_name'}}{'validated'}[$self->{'email_number'}];

    # Keep looking if the header we found is part of a "Begin Included
    # Message".
    my $end_of_string = substr($email, -200);
    if ($end_of_string =~
        /\n-----(?: Begin Included Message |Original Message)-----\n[^\n]*\n*$/i)
    {
      $GREP_DATA->{$self->{'file_name'}}{'lengths'}[$self->{'email_number'}] +=
        $GREP_DATA->{$self->{'file_name'}}{'lengths'}[$self->{'email_number'}+1];

      my $last_email_index = $#{$GREP_DATA->{$self->{'file_name'}}{'lengths'}};

      if($self->{'email_number'}+2 <= $last_email_index)
      {
        @{$GREP_DATA->{$self->{'file_name'}}{'lengths'}}
          [$self->{'email_number'}+1..$last_email_index] =
            @{$GREP_DATA->{$self->{'file_name'}}{'lengths'}}
            [$self->{'email_number'}+2..$last_email_index];

        @{$GREP_DATA->{$self->{'file_name'}}{'line_numbers'}}
          [$self->{'email_number'}+1..$last_email_index] =
            @{$GREP_DATA->{$self->{'file_name'}}{'line_numbers'}}
            [$self->{'email_number'}+2..$last_email_index];

        @{$GREP_DATA->{$self->{'file_name'}}{'offsets'}}
          [$self->{'email_number'}+1..$last_email_index] =
            @{$GREP_DATA->{$self->{'file_name'}}{'offsets'}}
            [$self->{'email_number'}+2..$last_email_index];
      }

      pop @{$GREP_DATA->{$self->{'file_name'}}{'lengths'}};
      pop @{$GREP_DATA->{$self->{'file_name'}}{'line_numbers'}};
      pop @{$GREP_DATA->{$self->{'file_name'}}{'offsets'}};
    }
    else
    {
      $GREP_DATA->{$self->{'file_name'}}{'validated'}[$self->{'email_number'}] = 1;
      last LOOK_FOR_NEXT_EMAIL;
    }
  }

  $self->{'end_of_file'} = 1
    if $self->{'email_number'} == 
      $#{$GREP_DATA->{$self->{'file_name'}}{'lengths'}};

  if ($UPDATING_CACHE)
  {
    dprint("Storing data into cache, length " .
      length($email)) if $DEBUG;

    $CACHE->{$self->{'file_name'}}{'lengths'}[$self->{'email_number'}] =
      length($email);

    $CACHE->{$self->{'file_name'}}{'line_numbers'}[$self->{'email_number'}]
=
      $self->{'email_line_number'};

    $CACHE->{$self->{'file_name'}}{'offsets'}[$self->{'email_number'}] =
      $self->{'email_offset'};

    $CACHE_MODIFIED = 1;
  }

  $self->{'email_number'}++;

  return \$email;
}

#-------------------------------------------------------------------------------

sub Has_Grep()
{
  unless (defined $HAS_GREP)
  {
    my $temp = `grep --help 2>&1`;
    if ($temp =~ /usage/i && $temp =~ /extended-reg/i &&
      $temp =~ /byte-offset/i && $temp =~ /line-numb/i)
    {
      $HAS_GREP = 1;
    }
    else
    {
      $HAS_GREP = 0;
    }
  }

  return $HAS_GREP;
}

#-------------------------------------------------------------------------------

# Reads an email from the file and returns it as a reference.
# Preconditions:
# - file handle is set and open
# - not end of file
sub read_next_email
{
  my $self = shift;

  if ($self->{'enable_cache'} && !$UPDATING_CACHE)
  {
    return $self->_cache_read_next_email();
  }
  elsif ($self->{'enable_grep'} && Has_Grep() &&
    defined $self->{'file_name'} && $self->{'file_name'} !~ /\.(gz|Z|bz2|tz)$/)
  {
    return $self->_grep_read_next_email();
  }
  else
  {
    return $self->_simple_read_next_email();
  }
}

1;
