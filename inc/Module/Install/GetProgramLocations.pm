#line 1 "inc/Module/Install/GetProgramLocations.pm - /Library/Perl/5.8.1/Module/Install/GetProgramLocations.pm"
package Module::Install::GetProgramLocations;

use strict;
use Config;
use Cwd;
use File::Spec;
use Sort::Versions;
use Exporter();

use vars qw( @ISA $VERSION @EXPORT );

use Module::Install::Base;
@ISA = qw( Module::Install::Base Exporter );

@EXPORT = qw( &Get_GNU_GPP_Version &Get_GNU_Grep_Version
              &Get_GNU_Make_Version &Get_Bzip2_Version );

$VERSION = sprintf "%d.%02d%02d", q/0.10.20/ =~ /(\d+)/g;

# ---------------------------------------------------------------------------

sub Get_Program_Locations
{
  my $self = shift;
  my %info = %{ shift @_ };

  # Module::Install says it requires perl 5.004
  $self->requires( perl => '5.004' );
  $self->include_deps('Config',0);
  $self->include_deps('File::Spec',0);
  $self->include_deps('Sort::Versions',0);
  $self->include_deps('Cwd',0);

  # By default the programs have no paths
  my %programs = map { $_ => undef } keys %info;

  my ($programs_ref,$program_specified_on_command_line) =
    $self->_Get_ARGV_Program_Locations(\%programs,\%info);
  %programs = %$programs_ref;

  return %programs if $program_specified_on_command_line;

  %programs = $self->_Prompt_User_For_Program_Locations(\%programs,\%info);

  return %programs;
}

# ---------------------------------------------------------------------------

sub _Get_ARGV_Program_Locations
{
  my $self = shift;
  my %programs = %{ shift @_ };
  my %info = %{ shift @_ };

  my $program_specified_on_command_line = 0;
  my @remaining_args;

  # Look for user-provided paths in @ARGV
  foreach my $arg (@ARGV)
  {
    my ($var,$value) = $arg =~ /^(.*?)=(.*)$/;
    $value = undef if $value eq '';

    if (!defined $var)
    {
      push @remaining_args, $arg;
    }
    else
    {
      my $is_a_program_arg = 0;

      foreach my $program (keys %info)
      {
        if ($var eq $info{$program}{'argname'})
        {
          $programs{$program} = $value;
          $program_specified_on_command_line = 1;
          $is_a_program_arg = 1;
        }
      }

      push @remaining_args, $arg unless $is_a_program_arg;
    }
  }

  @ARGV = @remaining_args;

  return (\%programs,$program_specified_on_command_line);
}

# ---------------------------------------------------------------------------

sub _Prompt_User_For_Program_Locations
{
  my $self = shift;
  my %programs = %{ shift @_ };
  my %info = %{ shift @_ };

  my @path = split /$Config{path_sep}/, $ENV{PATH};

  print "Enter the full path, or \"none\" for none.\n";

  my $last_choice = '';

  ASK: foreach my $program_name (sort keys %programs)
  {
    my ($name,$full_path);

    # Convert any default to a full path, initially
    $name = $Config{$program_name};
    $full_path = $self->can_run($name);

    if ($name eq '' || !defined $full_path)
    {
      $name = $info{$program_name}{'default'};
      $full_path = $self->can_run($name);
    }

    $full_path = 'none' if !defined $full_path || $name eq '';

    my $allowed_versions = '';
    if (exists $info{$program_name}{'versions'})
    {
      foreach my $type (keys %{ $info{$program_name}{'versions'} } )
      {
        $allowed_versions .= ", $type";
      }

      $allowed_versions =~ s/^, //;
      $allowed_versions =~ s/(.*), /$1, or /;
      $allowed_versions = " ($allowed_versions";
      $allowed_versions .=
        scalar(keys %{ $info{$program_name}{'versions'} }) > 1 ?
        " versions)" : " version)";
    }

    my $choice = $self->prompt(
      "Where can I find your \"$program_name\" executable?$allowed_versions" => $full_path);

    $programs{$program_name} = undef, next if $choice eq 'none';

    $choice = $self->_Make_Absolute($choice);

    if (!defined $self->can_run($choice))
    {
      print "\"$choice\" does not appear to be a valid executable\n";

      if ($last_choice ne $choice)
      {
        $last_choice = $choice;
        redo ASK;
      }

      print "Using anyway\n";
    }
    elsif(!$self->_Program_Version_Is_Valid($program_name,$choice,\%info))
    {
      print "\"$choice\" is not a correct version\n";

      if ($last_choice ne $choice)
      {
        $last_choice = $choice;
        redo ASK;
      }

      print "Using anyway\n";
    }

    $programs{$program_name} = $choice;
  }

  return %programs;
}

# ---------------------------------------------------------------------------

sub _Program_Version_Is_Valid
{
  my $self = shift;
  my $program_name = shift;
  my $program = shift;
  my %info = %{ shift @_ };

  if (exists $info{$program_name}{'versions'})
  {
    my $program_version;

    VERSION: foreach my $version (keys %{$info{$program_name}{'versions'}})
    {
      $program_version = 
        &{$info{$program_name}{'versions'}{$version}{'fetch'}}($program);

      next VERSION unless defined $program_version;

      if ($self->Version_Matches_Range($program_version,
        $info{$program_name}{'versions'}{$version}{'numbers'}))
      {
        return 1;
      }
    }

    my $program_version_string = '<UNKNOWN>';
    $program_version_string = $program_version if defined $program_version;
    print "\"$program\" version $program_version_string is not valid for any of the following:\n";

    foreach my $version (keys %{$info{$program_name}{'versions'}})
    {
      print "  $version => " .
        $info{$program_name}{'versions'}{$version}{'numbers'} . "\n";
    }

    return 0;
  }

  return 1;
}

# ---------------------------------------------------------------------------

sub Version_Matches_Range
{
  my $self = shift;
  my $version = shift;
  my $version_specification = shift;

  my $range_pattern = '([\[\(].*?\s*,\s*.*?[\]\)])';

  my @ranges = $version_specification =~ /$range_pattern/g;

  die "Version specification \"$version_specification\" is incorrect\n"
    unless @ranges;

  foreach my $range (@ranges)
  {
    my ($lower_bound,$lower_version,$upper_version,$upper_bound) =
      ( $range =~ /([\[\(])(.*?)\s*,\s*(.*?)([\]\)])/ );
    $lower_bound = '>' . ( $lower_bound eq '[' ? '=' : '');
    $upper_bound = '<' . ( $upper_bound eq ']' ? '=' : '');

    my ($lower_bound_satisified, $upper_bound_satisified);

    $lower_bound_satisified =
      ($lower_version eq '' || versioncmp($version,$lower_version) == 1 ||
      ($lower_bound eq '>=' && versioncmp($version,$lower_version) == 0));
    $upper_bound_satisified =
      ($upper_version eq '' || versioncmp($version,$upper_version) == -1 ||
      ($upper_bound eq '<=' && versioncmp($version,$upper_version) == 0));

    return 1 if $lower_bound_satisified && $upper_bound_satisified;
  }

  return 0;
}

# ---------------------------------------------------------------------------

sub _Make_Absolute
{
  my $self = shift;
  my $program = shift;

  if(File::Spec->file_name_is_absolute($program))
  {
    return $program;
  }
  else
  {
    my $path_to_choice = undef;

    foreach my $dir ((split /$Config::Config{path_sep}/, $ENV{PATH}), cwd())
    {
      $path_to_choice = File::Spec->catfile($dir, $program);
      last if defined $self->can_run($path_to_choice);
    }

    print "WARNING: Avoid security risks by converting to absolute paths\n";
    print "\"$program\" is currently in your path at \"$path_to_choice\"\n";

    return $path_to_choice;
  }
}

# ---------------------------------------------------------------------------

sub Get_GNU_Version
{
  my $program = shift;

  die "Missing GNU program to get version for" unless defined $program;

  my $version_message;

  # Newer versions
  {
    my $command = "$program --version 2>" . File::Spec->devnull();
    $version_message = `$command`;
  }

  # Older versions use -V
  unless($version_message =~ /\b(GNU|Free\s+Software\s+Foundation)\b/s)
  {
    my $command = "$program -V 2>&1 1>" . File::Spec->devnull();
    $version_message = `$command`;
  }

  return undef unless
    $version_message =~ /\b(GNU|Free\s+Software\s+Foundation)\b/s;

  my ($program_version) = $version_message =~ /^.*?([\d]+\.[\d.a-z]+)/s;

  return $program_version;
}

# ---------------------------------------------------------------------------

sub Get_GNU_GPP_Version
{
  my $self = shift;
  my $program = shift;

  return Get_GNU_Version($program);
}

# ---------------------------------------------------------------------------

sub Get_GNU_Grep_Version
{
  my $self = shift;
  my $program = shift;

  return Get_GNU_Version($program);
}

# ---------------------------------------------------------------------------

sub Get_GNU_Make_Version
{
  my $self = shift;
  my $program = shift;

  return Get_GNU_Version($program);
}

# ---------------------------------------------------------------------------

sub Get_Bzip2_Version
{
  my $self = shift;
  my $program = shift;

  my $command = "$program --help 2>&1 1>" . File::Spec->devnull();
  my $version_message = `$command`;

  my ($program_version) = $version_message =~ /^.*?([\d]+\.[\d.a-z]+)/s;

  return $program_version;
}

1;

# ---------------------------------------------------------------------------

#line 530

