#line 1 "inc/File/HomeDir.pm - /Library/Perl/5.8.1/File/HomeDir.pm"
 
require 5;
package File::HomeDir;   #Time-stamp: "2000-12-09 15:42:33 MST"
use strict;
use vars qw($HOME @EXPORT $VERSION @ISA %Cache);
$VERSION = '0.05';
use Carp ();
require Exporter;
@ISA = ('Exporter');
@EXPORT = ('home');
 # %~ doesn't need (and won't take) exporting, as it's a magic symbol name
 # that's always looked for in package 'main'.

# POD at end.

sub my_home () {
  return $HOME if defined $HOME;

  # try the obvious
  $HOME = $ENV{'HOME'} || $ENV{'LOGDIR'};
  return $HOME if $HOME;
    
  # Or try other ways...
  if($MacPerl::Version and $MacPerl::Version
    # avoid the "used only once" warning.
    and defined do {
      local $SIG{"__DIE__"} = "";
      eval
       'use Mac::Files; $HOME = FindFolder(kOnSystemDisk, kDesktopFolderType)'
    }
  ) {
    return $HOME;
  }

  if(defined do {
    # see if there's a W32 registry on this machine, and if so, look in it
    local $SIG{"__DIE__"} = "";
    eval '
      use Win32::TieRegistry;
      my $folders = Win32::TieRegistry->new(
         "HKEY_CURRENT_USER/Software/Microsoft/Windows/CurrentVersion/Explorer/Shell Folders",
         { Delimiter => "/" }
      );
      $HOME = $folders->GetValue("Desktop");
    ' }
  ) {
    return $HOME;
  }

  # Getting desperate now...
  if( defined eval
    {
      local $SIG{'__DIE__'} = '';
      $HOME = (getpwuid($<))[7];
    }
  ) {
    return $HOME;
  }

  # MSWindows sets WINDIR, MS WinNT sets USERPROFILE.

  if($ENV{'USERPROFILE'}) {   # helpfully suggested by crysflame
    if(-e "$ENV{'USERPROFILE'}\\Desktop") {
      $HOME = "$ENV{'USERPROFILE'}\\Desktop";
      return $HOME;
    }
  } elsif($ENV{'WINDIR'}) {
    if(-e "$ENV{'WINDIR'}\\Desktop") {
      $HOME = "$ENV{'WINDIR'}\\Desktop";
      return $HOME;
    }
  }

  # try even harder
  if( -e 'C:/windows/desktop' ) {
    $HOME = 'C:/windows/desktop';
    return $HOME;
  } elsif( -e 'C:/win95/desktop' ) {
    $HOME = 'C:/win95/desktop';
    return $HOME;
  }

  # Ah well, if all else fails, fail...
  die "Can't find ~/";
}


sub home (;$) {
  if(@_ == 0) {
    $HOME || my_home();
  } elsif(!defined $_[0]) {
    Carp::croak "Can't use undef as a username";
  } elsif(!length $_[0]) {
    Carp::croak "Can't use empty-string (\"\") as a username";
  } elsif($_[0] eq '.') {
    $HOME || my_home();
  } else {
    exists( $Cache{$_[0]} )  # Memoization
     ? $Cache{$_[0]}
     : do {
       local $SIG{'__DIE__'} = '';
       $Cache{$_[0]} = eval { (getpwnam($_[0]))[7] };
        # ...so that on machines where getpwnam causes
        # a fatal error when called at all, we avoid outright
        # dying, and just return the undef that we'll get from
        # a failed eval block.
     }
  }
}

# Okay, things below this point are all scary.
#--------------------------------------------------------------------------
{
  # Make the class for the %~ tied hash:

  package File::HomeDir::TIE;
  use vars qw($o);

  # Make the singleton object:
  $o = bless {}; # We don't use the hash for anything, tho.

  sub TIEHASH { $o }
  sub FETCH   {
    #print "Fetching $_[1]\n";
    if(!defined($_[1]))   { &File::HomeDir::home()      }
    elsif(!length($_[1])) { &File::HomeDir::home()      }
    else                  {
      my $x = &File::HomeDir::home($_[1]);
      Carp::croak "No home dir found for user \"$_[1]\"" unless defined $x;
      $x;
    }
  }

  foreach my $m (qw(STORE EXISTS DELETE CLEAR FIRSTKEY NEXTKEY)) {
    no strict 'refs';
    *{$m} = sub { Carp::croak "You can't try ${m}ing with the %~ hash" }
  }  

  # For a more generic approach to this sort of thing, see Dominus's
  # class "Interpolation" in CPAN.
}

#--------------------------------------------------------------------------
tie %~, 'File::HomeDir::TIE';  # Finally.
1;

__END__

#line 236

#What it says is, and I quote:
#
#|
#|#ifdef  WINDOWSNT
#|          /* DebPrint(("EMACS broken @-"__FILE__ ": %d\n", __LINE__)); */
#|          /*
#|           * Emacs wants to know the user's home directory...  This is set by
#|           * the user-manager, but how do I get that information from the
#|           * system?
#|           *
#|           * After a bit of hunting I discover that the user's home directroy
#|           * is stored at:  "HKEY_LOCAL_MACHINE\\security\\sam\\"
#|           * "domains\\account\\users\\<account-rid>\\v" in the registry...
#|           * Now I could pull it out but this location only contains local
#|           * accounts... so if you're logged on to some non-local domain this
#|           * may run into a security problem... i.e. I may not always be able
#|           * to read this information even for myself...
#|           *
#|           * What's here is a hack to make things work...
#|           */
#|
#|          newdir = (unsigned char *) egetenv ("HOME");
#|#else /* !WINDOWSNT */
#|          pw = (struct passwd *) getpwnam (o + 1);
#|          if (pw)
#|            {
#|              newdir = (unsigned char *) pw -> pw_dir;
#|#ifdef VMS
#|              nm = p + 1;       /* skip the terminator */
#|#else
#|              nm = p;
#|#endif                          /* VMS */
#|            }
#|#endif /* !WINDOWSNT */
#|

#line 290

