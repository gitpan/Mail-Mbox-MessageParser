#!/usr/bin/perl

# Test the method of reading a mailbox that relies on undef rather than
# checking EOF

use strict;

use Test::More;
use lib 't';
use Mail::Mbox::MessageParser;
use Mail::Mbox::MessageParser::Config;
use File::Spec::Functions qw(:ALL);
use Test::Utils;
use FileHandle;

eval 'require Storable;';

my @files = <t/mailboxes/*.txt>;

mkdir catfile('t','temp'), 0700;

plan (tests => 3 * scalar (@files));

foreach my $filename (@files)
{
	print "Testing Perl \n";

	TestImplementation($filename,0,0);

	SKIP:
	{
		skip('Storable not installed',1) unless defined $Storable::VERSION;

		InitializeCache($filename);

		print "Testing Cache implementation\n";

		TestImplementation($filename,1,0);
	}

	SKIP:
	{
		skip('GNU grep not available',1)
			unless defined $Mail::Mbox::MessageParser::Config{'programs'}{'grep'};

		print "Testing Grep implementation\n";

		TestImplementation($filename,0,1);
	}
}

# ---------------------------------------------------------------------------

sub TestImplementation
{
  my $filename = shift;
  my $enable_cache = shift;
  my $enable_grep = shift;

  my $testname = [splitdir($0)]->[-1];
  $testname =~ s/\.t//;

  my ($folder_name) = $filename =~ /\/([^\/]*)\.txt$/;

  my $output_filename = catfile('t','temp',
    "${testname}_${folder_name}_${enable_cache}_${enable_grep}.stdout");

  my $output = new FileHandle(">$output_filename");
  binmode $output;

  my $filehandle = new FileHandle($filename);

  my $cache_file = catfile('t','temp','cache');

  Mail::Mbox::MessageParser::SETUP_CACHE({'file_name' => $cache_file})
    if $enable_cache;

  my $folder_reader =
      new Mail::Mbox::MessageParser( {
        'file_name' => $filename,
        'file_handle' => $filehandle,
        'enable_cache' => $enable_cache,
        'enable_grep' => $enable_grep,
      } );

  die $folder_reader unless ref $folder_reader;

  print $output $folder_reader->prologue;

  # This is the main loop. It's executed once for each email
  while(my $email = $folder_reader->read_next_email())
  {
    print $output $$email;
  }

  $output->close();

  CheckDiffs([$filename,$output_filename]);
}

# ---------------------------------------------------------------------------

